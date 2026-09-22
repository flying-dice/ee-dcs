/** @noSelfInFile */
// DCS engine-boundary diagnostics, not EECH campaign policy. Observation times
// come from issue #3's reproduction plan; they never trigger retries or refunds.
import * as cs from "./campaign_state";
import type { SpawnItem } from "./campaign_types";

type GroupSpawn = Extract<SpawnItem, { kind: "group" }>;
type Logger = (this: void, message: string) => void;
interface Probe {
	item: GroupSpawn;
	started: number;
	log: Logger;
}
const SAMPLE_SECONDS = [1, 5, 30, 120];
// Ephemeral observers belong to this loaded module, not persisted campaign state.
const watched = new Map<string, Probe>();
let listening = false;

function emit(probe: Probe, message: string): void {
	pcall(
		probe.log,
		`[spawn_probe] gen=${cs.GENERATION} seq=${probe.item.seq} group=${probe.item.name} ${message}`,
	);
}

function read(query: () => unknown): string {
	const [ok, value] = pcall(query);
	return ok ? tostring(value) : `QUERY_ERROR(${tostring(value)})`;
}

function attributes(unit: Unit): string {
	const result: string[] = [];
	for (const [name, enabled] of pairs(unit.getDesc().attributes)) {
		if (enabled) result.push(name);
	}
	result.sort();
	return result.join(",");
}

function sample(probe: Probe): void {
	emit(
		probe,
		`phase=sample elapsed=${timer.getTime() - probe.started} group_exists=${read(() => Group.getByName(probe.item.name)?.isExist() ?? false)} group_size=${read(() => Group.getByName(probe.item.name)?.getSize())}`,
	);
	for (const expected of probe.item.data.units) {
		const [ok, unit] = pcall(() => Unit.getByName(expected.name));
		if (!ok) {
			emit(
				probe,
				`unit=${expected.name} lookup=QUERY_ERROR(${tostring(unit)})`,
			);
			continue;
		}
		if (!unit) {
			emit(probe, `unit=${expected.name} present=false`);
			continue;
		}
		emit(
			probe,
			`unit=${expected.name} present=true exists=${read(() => unit.isExist())} active=${read(() => unit.isActive())} life=${read(() => unit.getLife())} in_air=${read(() => unit.inAir())} position=${read(
				() => {
					const p = unit.getPoint();
					return `${p.x},${p.y},${p.z}`;
				},
			)} agl=${read(() => {
				const p = unit.getPoint();
				return p.y - land.getHeight({ x: p.x, y: p.z });
			})} attributes=${read(() => attributes(unit))}`,
		);
	}
}

const handler: DcsEventHandler = {
	onEvent(event) {
		if (_DMT_GEN !== cs.GENERATION || !_DMT_DEBUG) return;
		if (
			event.id !== world.event.S_EVENT_BIRTH &&
			event.id !== world.event.S_EVENT_TAKEOFF &&
			event.id !== world.event.S_EVENT_DEAD &&
			event.id !== world.event.S_EVENT_CRASH
		)
			return;
		const [ok, name] = pcall(() => event.initiator?.getName());
		if (!ok || !name) return;
		const probe = watched.get(name);
		if (probe)
			emit(
				probe,
				`phase=event id=${event.id} unit=${name} elapsed=${timer.getTime() - probe.started}`,
			);
	},
};

function describeBase(probe: Probe): void {
	const departure = probe.item.data.route?.points[0];
	const reference = departure?.helipadId ?? departure?.airdromeId;
	if (reference === undefined) {
		emit(probe, "base_reference=none (ground/air start)");
		return;
	}
	let matched = false;
	for (const name of Object.keys(cs.S.base_pos)) {
		const [ok, base] = pcall(() => Airbase.getByName(name));
		if (!ok) {
			emit(probe, `base=${name} lookup=QUERY_ERROR(${tostring(base)})`);
			continue;
		}
		if (!base || read(() => base.getID()) !== tostring(reference)) continue;
		matched = true;
		emit(
			probe,
			`base=${name} id=${reference} category=${read(() => base.getDesc().category)} coalition=${read(() => base.getCoalition())} static_id=${read(() => StaticObject.getByName(name)?.getID())} position=${read(
				() => {
					const p = base.getPosition().p;
					return `${p.x},${p.y},${p.z}`;
				},
			)}`,
		);
		for (const available of [false, true]) {
			emit(
				probe,
				`base=${name} parking_available_only=${available} parking=${read(() =>
					base
						.getParking(available)
						.map(
							(spot) =>
								`${spot.Term_Index}:${spot.Term_Type}:${spot.vTerminalPos.x},${spot.vTerminalPos.y},${spot.vTerminalPos.z}:TO_AC=${spot.TO_AC}`,
						)
						.join(";"),
				)}`,
			);
		}
	}
	if (!matched)
		emit(probe, `base_reference=${reference} matching_campaign_airbase=false`);
}

function forget(probe: Probe): void {
	for (const unit of probe.item.data.units) {
		if (watched.get(unit.name) === probe) watched.delete(unit.name);
	}
	if (watched.size === 0 && listening) {
		pcall(() => world.removeEventHandler(handler));
		listening = false;
	}
}

/** Called before the real API, so synchronous birth events are captured. */
export function begin(item: SpawnItem, log: Logger): Probe | undefined {
	if (
		!_DMT_DEBUG ||
		item.kind !== "group" ||
		item.category !== Group.Category.HELICOPTER
	)
		return undefined;
	const probe = { item, started: timer.getTime(), log };
	const [ok, failure] = pcall(() => {
		for (const unit of item.data.units) watched.set(unit.name, probe);
		if (!listening) {
			world.addEventHandler(handler);
			listening = true;
		}
		const p = item.data.route?.points[0];
		emit(
			probe,
			`probe_version=1 submitted_at=${probe.started} launch_base=${cs.S.group_launch_base[item.name] ?? "unregistered"} deferred_set_task=${item.deferred_setTask !== undefined} deferred_push_task=${item.deferred_pushTask !== undefined}`,
		);
		emit(
			probe,
			`phase=submitted country=${item.country} expected=${item.data.units.length} type=${tostring(p?.type)} action=${tostring(p?.action)} airdrome=${tostring(p?.airdromeId)} helipad=${tostring(p?.helipadId)} link=${tostring(p?.linkUnit)} hidden=${tostring(item.data.hidden)} late_activation=${tostring(item.data.lateActivation)} uncontrolled=${tostring(item.data.uncontrolled)} start_time=${tostring(item.data.start_time)} departure=${tostring(p?.x)},${tostring(p?.y)},${tostring(p?.alt)}`,
		);
		for (const unit of item.data.units) {
			emit(
				probe,
				`requested_unit=${unit.name} type=${unit.type} parking=${tostring(unit.parking)} parking_id=${tostring(unit.parking_id)} position=${unit.x},${unit.y},${tostring(unit.alt)} fuel=${tostring(unit.payload?.fuel)} pylons=${unit.payload?.pylons?.map((pylon) => `${pylon.num}:${pylon.CLSID}`).join(",") ?? "none"}`,
			);
		}
		describeBase(probe);
	});
	if (!ok) emit(probe, `phase=diagnostic_error detail=${tostring(failure)}`);
	return probe;
}

export function finish(
	probe: Probe | undefined,
	outcome: "returned" | "nil" | "threw",
): void {
	if (!probe) return;
	const [ok, failure] = pcall(() => {
		emit(
			probe,
			`phase=api_result outcome=${outcome} (not proof of materialisation)`,
		);
		sample(probe);
		let index = 0;
		timer.scheduleFunction(
			() => {
				if (_DMT_GEN !== cs.GENERATION || !_DMT_DEBUG) {
					forget(probe);
					return undefined;
				}
				const [sampled, reason] = pcall(() => sample(probe));
				if (!sampled)
					emit(probe, `phase=diagnostic_error detail=${tostring(reason)}`);
				index++;
				if (index === SAMPLE_SECONDS.length) {
					emit(
						probe,
						"phase=observation_complete (no failure or refund inferred)",
					);
					forget(probe);
					return undefined;
				}
				return probe.started + SAMPLE_SECONDS[index];
			},
			undefined,
			probe.started + SAMPLE_SECONDS[0],
		);
	});
	if (!ok) {
		emit(probe, `phase=diagnostic_error detail=${tostring(failure)}`);
		forget(probe);
	}
}
