/** @noSelfInFile */
/*
-- aircraft_lifecycle.ts
-- EECH source:
--   aphavoc/source/ai/taskgen/assign.c              assign_keysite_tasks (:245-296) — the assignment
--                                                   pass calls assign_primary_task_to_group and
--                                                   COMMITS NOTHING when it returns FALSE: the task
--                                                   is not re-listed, the per-keysite assign budget
--                                                   is not decremented, and the task is simply tried
--                                                   again on the next pass. assign_primary_task_to_
--                                                   group (:524-620) likewise gates every side
--                                                   effect (formation, keysite relink,
--                                                   ENTITY_MESSAGE_TASK_ASSIGNED to FORCE, escort
--                                                   assessment) behind a successful
--                                                   assign_task_to_group. Assignment is all-or-
--                                                   nothing in the C, and so is an allocation here.
--   aphavoc/source/entity/special/task/ts_msgs.c    response_to_link_parent (:128-152): a task's
--                                                   TASK_STATE is a function of the LIST it is
--                                                   linked into — re-linking to
--                                                   LIST_TYPE_UNASSIGNED_TASK sets it back to
--                                                   TASK_STATE_UNASSIGNED. That is the C's own
--                                                   "put it back on the board" transition.
--   aphavoc/source/entity/special/task/ts_updt.c    update_server (:99-124): an UNASSIGNED task
--                                                   counts down its expire_timer and terminates at
--                                                   zero. That IS the retry window; EECH has no
--                                                   separate retry cadence and neither does this
--                                                   module — a reversed allocation goes back to the
--                                                   existing board and the existing expiry.
--   aphavoc/source/entity/system/en_types/en_task.h TASK_STATE_TYPES (:83-90).
--
-- WHY THIS MODULE EXISTS — a documented DCS divergence, not an EECH behaviour.
-- In shipped EECH the assignment target is an aircraft group that ALREADY EXISTS at a keysite
-- (assign.c:259 get_suitable_registered_group), so "the aircraft failed to come into existence"
-- is not a state the C code can reach. This port spawns on assignment instead (the proxy is
-- documented in task_board.ts's header), and spawn_queue.ts defers the real coalition.addGroup by
-- up to a drain tick, handing the caller a lazy proxy in the meantime. That opens a gap the C
-- source has no analogue for: task_board commits the ledger debit, the keysite slot, the task
-- registration and TASK_STATE_ASSIGNED against a group DCS has not yet been asked to create.
--
-- This module is the typed request/result link across that gap. It records the allocation FACTS at
-- debit time — side, base, role, debited count, task id, group name, expected unit names, slot
-- ownership, generation — so that nothing downstream has to re-derive them from a group-name
-- prefix, and settles them against what the real API actually did. One rule governs settlement:
--
--   UNKNOWN IS NOT FAILED. Only a PROVEN no-creation reverses an allocation: the API returned nil
--   or threw, AND no S_EVENT_BIRTH arrived for any expected unit, AND no group of that name is
--   visible afterwards. A throw after a birth, a partially created group, or a failed query leaves
--   the allocation committed and the attempt visible as unresolved — never refunded, never
--   respawned. Reversing an allocation whose aircraft DOES exist would double-credit the reserve
--   and strand a live group, which is strictly worse than carrying a known-unknown on the books.
--
-- DELIBERATE LIMIT (no invented constant — PRIME DIRECTIVE). Settlement is synchronous with the
-- drain-time API call, because any deferred re-check would need a settlement delay and there is no
-- EECH value to source one from. DCS creates the group synchronously inside coalition.addGroup —
-- spawn_queue's own proxy relies on exactly that when it resolves Group.getByName — so an
-- immediate Group.getByName is the primary evidence and the BIRTH watch armed BEFORE the call is
-- the corroborating synchronous signal. A birth delivered on a LATER frame after a nil return is
-- therefore not correlated and resolves as a proven failure. Recorded here as a known divergence
-- rather than papered over with a made-up timeout.
--
-- LIFETIME. The registry is per-process and module-local, the same choice spawn_diagnostics.ts
-- makes and for the same reason: the records hold live closures and DCS handles, so they are not
-- persistable campaign state. Every record carries the generation it was created in and is fenced
-- by it, so a re-injection can never settle or refund into the fresh campaign's state table. A
-- generation fence alone cannot cancel ONE attempt, so each attempt also carries its own cancel
-- flag, which is what fences a request-owned delayed callback (schedule_for).
--
-- P4 — VIRTUAL RETIREMENT (a DCS proxy, NOT an EECH behaviour; see retire_sortie below).
-- Four campaign timers end a sortie on a clock rather than on the aircraft coming home:
-- reaction's CAP station expiry, the BDA loiter, supply_flight's route backstop and troop's
-- insertion TTL. Before P4 each of those hand-rolled its own recycle/release/destroy/clear,
-- which gave a supply flight TWO independent owners of its reserve credit: the backstop credited
-- by GROUP name while the recovery path credited by UNIT name, so an aircraft that landed and was
-- then swept by its backstop was counted home twice (ADR 0010 "Consequences"). They now settle
-- through retire_sortie(), which is the same per-airframe path a real recovery uses, under the
-- same budget and the same per-unit guard — so the second owner cannot exist. The outcome is
-- labelled `virtual_*` in stats() precisely because it is NOT live RTB evidence: no LAND event
-- was seen, no landing site was read, and the credit rests on the airframe still existing when
-- the timer fired.
--
-- P4 — `S._recycled` KEY NAMESPACE. `S._recycled` is one shared table. The settlement path here
-- owns the `unit:` namespace and nothing else (recycledKey below). Historically reaction and
-- supply_flight wrote bare GROUP names into the same table; no collision was possible because a
-- unit name is `<group>-<n>`, but the two spaces were only accidentally disjoint. Those two
-- group-keyed writers are gone (their timers now settle here), and the remaining namespace is
-- explicit so a future group-keyed user has to choose a prefix rather than inherit a coincidence.
*/
import * as cs from "./campaign_state";
import type { BoardRole, LogFunction, Side, SpawnItem } from "./campaign_types";

const S = cs.S;

/** The reserve roles supply.ledger actually carries (BoardRole minus the human slot). */
export type ReserveRole = Exclude<BoardRole, "player">;

/** What the real `coalition.addGroup` did, as observed by spawn_queue.drain. */
export type AttemptOutcome = "returned" | "nil" | "threw";

/**
 * How an attempt was settled. Only `failed_no_creation` and `cancelled` are proof that no
 * aircraft exists; everything else either created something or could not be proven either way.
 */
export type AttemptResolution =
	| "pending"
	| "created"
	| "created_partial"
	| "created_unverified"
	| "failed_no_creation"
	| "ambiguous"
	| "cancelled";

export interface AllocationFacts {
	task_id?: number;
	task_type: string;
	side: Side;
	/** The base whose ledger was debited. Recorded so the refund cannot guess. */
	base: string;
	role: ReserveRole;
	/** Exactly what was debited, so exactly that much is given back. */
	count: number;
	log_fn?: LogFunction;
	/** Called once, after the reserve/slot/task reversal, so the owner can requeue. */
	on_reverted?: (this: void, reason: string) => void;
	/**
	 * Whether this allocation's aircraft can ever come BACK and be credited (P4).
	 *
	 * Default true: commit_allocation opens a recovery record per attempt, so the allocation's
	 * own role and expected unit names — not a group-name prefix — decide the settlement.
	 *
	 * `false` is for an allocation that spawns an aircraft which is NOT a sortie: `regen`'s
	 * replacement airframes are the debit made physical (they are parked idle stock with no
	 * route past the departure waypoint), so opening a recovery record for one would both
	 * misdescribe it and grow the registry without bound on a long-running server. Whether that
	 * permanent debit is itself correct is a deferred question with no EECH citation yet
	 * (sprint 04, "deferred asymmetries") — this flag preserves today's behaviour exactly, it
	 * does not decide it.
	 */
	recovery?: boolean;
}

export interface AircraftAttempt {
	id: number;
	generation: number;
	allocation_id?: number;
	/** spawn_queue sequence number of the deferred request. */
	seq: number;
	group_name: string;
	expected_units: string[];
	/** True once the real API has been invoked for this attempt. */
	submitted: boolean;
	cancelled: boolean;
	birth_seen: boolean;
	observed_units?: number;
	outcome?: AttemptOutcome;
	resolution: AttemptResolution;
	detail?: string;
}

export interface AircraftAllocation extends AllocationFacts {
	id: number;
	generation: number;
	attempts: AircraftAttempt[];
	/**
	 * True once the builder has returned, success or not. Until then attempts may still be
	 * attached and nothing may be settled.
	 */
	closed: boolean;
	reverted: boolean;
	group_name?: string;
	/** Group name that owns the keysite launch slot, or undefined if this allocation took none. */
	slot_group?: string;
	/** Group name registered in S.active_tasks on behalf of this allocation. */
	registered_group?: string;
}

let sequence = 0;
const attempts = new Map<number, AircraftAttempt>();
const allocations = new Map<number, AircraftAllocation>();
/** Innermost-open allocation stack, so a nested builder attaches to its OWN allocation. */
const openScopes: AircraftAllocation[] = [];
/** Expected unit name -> attempt, armed only across the real API call. */
const armedUnits = new Map<string, AircraftAttempt>();
let listening = false;

/** Innermost scope still accepting attachments, discarding any that were already closed. */
function currentScope(): AircraftAllocation | undefined {
	while (openScopes.length > 0) {
		const top = openScopes[openScopes.length - 1];
		if (!top.closed && !top.reverted) return top;
		openScopes.pop();
	}
	return undefined;
}

let refundedAllocations = 0;
let ambiguousAttempts = 0;
let duplicateSettlements = 0;

function generation(): number {
	return _DMT_GEN ?? 0;
}

// ── birth correlation ────────────────────────────────────────────────────────────────────────
// Armed before the real API call so a BIRTH raised synchronously inside coalition.addGroup is
// seen. Disarmed the moment the attempt settles, so this handler never outlives a submission and
// never stacks across re-injections (reset.nuke only sweeps _G.__dmt_handlers).

const birthHandler: DcsEventHandler = {
	onEvent(event) {
		if (event.id !== world.event.S_EVENT_BIRTH) return;
		const [ok, name] = pcall(() => event.initiator?.getName());
		if (!ok || name === undefined) return;
		const attempt = armedUnits.get(name);
		if (attempt !== undefined) attempt.birth_seen = true;
	},
};

function arm(attempt: AircraftAttempt): void {
	for (const unit of attempt.expected_units) armedUnits.set(unit, attempt);
	if (!listening) {
		const [ok] = pcall(() => world.addEventHandler(birthHandler));
		listening = ok;
	}
}

function disarm(attempt: AircraftAttempt): void {
	for (const unit of attempt.expected_units) {
		if (armedUnits.get(unit) === attempt) armedUnits.delete(unit);
	}
	if (armedUnits.size === 0 && listening) {
		pcall(() => world.removeEventHandler(birthHandler));
		listening = false;
	}
}

// ── allocation ───────────────────────────────────────────────────────────────────────────────

/**
 * Opens an allocation around a builder call. MUST be paired with commit_allocation or
 * abort_allocation, which pop the scope. The caller has already taken the debit described by
 * `facts`; from here the allocation owns it.
 */
export function begin_allocation(facts: AllocationFacts): AircraftAllocation {
	sequence += 1;
	const allocation: AircraftAllocation = {
		id: sequence,
		generation: generation(),
		task_id: facts.task_id,
		task_type: facts.task_type,
		side: facts.side,
		base: facts.base,
		role: facts.role,
		count: facts.count,
		log_fn: facts.log_fn,
		on_reverted: facts.on_reverted,
		recovery: facts.recovery,
		attempts: [],
		closed: false,
		reverted: false,
	};
	allocations.set(allocation.id, allocation);
	openScopes.push(allocation);
	return allocation;
}

/**
 * Ends the window in which track() may attach to this allocation. Call it as soon as the builder
 * returns: nothing after that point spawns, so leaving the scope open would let an unrelated
 * later spawn attach to a dead allocation if anything in between raised. Idempotent.
 */
export function close_scope(allocation: AircraftAllocation): void {
	for (let i = openScopes.length - 1; i >= 0; i -= 1) {
		if (openScopes[i] === allocation) {
			openScopes.splice(i, 1);
			return;
		}
	}
}

/**
 * Called by an aircraft builder immediately after its (intercepted) coalition.addGroup, to link
 * the deferred spawn request to the allocation whose builder is running. Returns undefined when
 * the spawn was not deferred (no spawn_queue interception installed) — callers keep working.
 */
export function track(group: Group | undefined): AircraftAttempt | undefined {
	if (group === undefined) return undefined;
	const item = (group as unknown as { __item?: SpawnItem }).__item;
	if (item === undefined || item.kind !== "group") return undefined;
	if (item.attempt_id !== undefined) return attempts.get(item.attempt_id);
	sequence += 1;
	const expected: string[] = [];
	for (const unit of item.data.units) expected.push(unit.name);
	const attempt: AircraftAttempt = {
		id: sequence,
		generation: generation(),
		seq: item.seq,
		group_name: item.name,
		expected_units: expected,
		submitted: false,
		cancelled: false,
		birth_seen: false,
		resolution: "pending",
	};
	attempts.set(attempt.id, attempt);
	item.attempt_id = attempt.id;
	const allocation = currentScope();
	if (allocation !== undefined) {
		attempt.allocation_id = allocation.id;
		allocation.attempts.push(attempt);
	}
	cs.dbg(
		"lifecycle",
		"attempt #%d tracked group=%s seq=%d units=%d alloc=%s",
		attempt.id,
		attempt.group_name,
		attempt.seq,
		expected.length,
		tostring(allocation?.id),
	);
	return attempt;
}

/**
 * The builder succeeded. Records what the allocation now owns physically so a later reversal
 * gives back exactly that and no more.
 */
export function commit_allocation(
	allocation: AircraftAllocation,
	groupName?: string,
	slotGroup?: string,
	registeredGroup?: string,
): void {
	close_scope(allocation);
	allocation.closed = true;
	allocation.group_name = groupName;
	allocation.slot_group = slotGroup;
	allocation.registered_group = registeredGroup;
	if (allocation.attempts.length === 0) {
		// Builder did not opt into lifecycle tracking: behaviour is exactly as before this module.
		allocations.delete(allocation.id);
		return;
	}
	// P3: the recovery record is opened here, while the allocation facts are still in hand. From
	// this point settlement consults the DEBITED role and the EXPECTED unit names, never a
	// group-name prefix, and the record outlives cs.clear_task().
	// P4: `recovery: false` says this allocation's airframes are not a sortie and can never come
	// back (regen's parked replacements) — no record is opened, so nothing can credit them and
	// the registry does not accumulate entries that never terminate.
	if (allocation.recovery !== false) {
		for (const attempt of allocation.attempts) {
			if (attempt.cancelled || attempt.resolution === "cancelled") continue;
			const task = cs.get_task(attempt.group_name);
			register_sortie({
				group_name: attempt.group_name,
				side: allocation.side,
				role: allocation.role,
				debit_base: allocation.base,
				unit_names: attempt.expected_units,
				// One allocation, one group in every current caller; a package that ever spawns
				// two groups from one debit must not let either credit the whole of it.
				budget:
					allocation.attempts.length === 1
						? allocation.count
						: attempt.expected_units.length,
				task_type: task?.task_type ?? allocation.task_type,
				target_base: task?.target_base,
				tracked: true,
			});
		}
	}
	evaluate(allocation, "commit");
}

/**
 * The builder failed synchronously. Cancels any spawn it had already queued (so no orphan group
 * drains into the world later) and reverses the allocation.
 *
 * The allocation OWNS the debit, so this call always takes responsibility for it and the caller
 * must never refund as well. Returns false — meaning "reversed nothing, deliberately" — when a
 * tracked attempt already proved an aircraft exists (the debit is correctly kept) or when the
 * generation fence fired.
 */
export function abort_allocation(
	allocation: AircraftAllocation,
	reason: string,
): boolean {
	close_scope(allocation);
	allocation.closed = true;
	for (const attempt of allocation.attempts) {
		if (
			attempt.resolution !== "pending" &&
			attempt.resolution !== "cancelled" &&
			attempt.resolution !== "failed_no_creation"
		) {
			cs.dbg(
				"lifecycle",
				"alloc #%d builder FAILED but attempt #%d is %s — debit kept, nothing reversed",
				allocation.id,
				attempt.id,
				attempt.resolution,
			);
			allocations.delete(allocation.id);
			return false;
		}
	}
	for (const attempt of allocation.attempts) cancel_attempt(attempt, reason);
	return revert(allocation, reason);
}

/**
 * Gives back exactly what this allocation took: the keysite slot it reserved, the task record it
 * registered, and the exact debited count. Runs at most once per allocation.
 */
function revert(allocation: AircraftAllocation, reason: string): boolean {
	if (allocation.reverted) return false;
	if (allocation.generation !== generation()) {
		// A re-injection replaced the whole state table. Crediting the new campaign's ledger for
		// the old one's debit would invent stock; fence it off and leave it reverted-by-staleness.
		allocation.reverted = true;
		allocations.delete(allocation.id);
		cs.dbg(
			"lifecycle",
			"alloc #%d STALE (gen %d, now %d) — no refund, no retry (%s)",
			allocation.id,
			allocation.generation,
			generation(),
			reason,
		);
		return false;
	}
	allocation.reverted = true;
	// Lazily required: spawn_queue loads this module before config.load_and_validate runs, and
	// supply captures config values at ITS module load. Importing supply eagerly here would
	// freeze the pre-config defaults.
	const supply = require<typeof import("./supply")>("supply");
	const keysite = require<typeof import("./keysite")>("keysite");
	if (allocation.slot_group !== undefined)
		keysite.release_slot(allocation.slot_group);
	if (allocation.registered_group !== undefined)
		cs.clear_task(allocation.registered_group);
	// Physical stands are part of what this allocation took, so they come back with the ledger
	// debit and the keysite slot — and ONLY this allocation's own stands. A pad held by another
	// allocation, or by a live/player aircraft via TO_AC, is untouched.
	release_stands_for_allocation(allocation.id, reason);
	// The aircraft was PROVEN never to have existed, so there is nothing to recover: drop the
	// recovery record rather than leave it able to credit a second time on top of this refund.
	for (const attempt of allocation.attempts) drop_sortie(attempt.group_name);
	if (S.base_owner[allocation.base] === allocation.side)
		supply.recycle_base(allocation.base, allocation.role, allocation.count);
	// The launch base changed hands between the debit and the failure. Crediting it back there
	// would hand the airframes to the captor (base_ledger travels with the base, keysite.ts:916-927),
	// so the allocating side gets its own reserve back instead.
	else supply.recycle_side(allocation.side, allocation.role, allocation.count);
	refundedAllocations += 1;
	if (allocation.log_fn !== undefined)
		allocation.log_fn(
			string.format(
				"%s %s launch from %s never reached DCS (%s) — %d x %s returned to the reserve, task re-listed",
				cs.SIDE_NAME[allocation.side],
				allocation.task_type,
				allocation.base,
				reason,
				allocation.count,
				allocation.role,
			),
		);
	cs.dbg(
		"lifecycle",
		"alloc #%d REVERSED: %s %d x %s back to %s, slot=%s task=%s (%s)",
		allocation.id,
		cs.SIDE_NAME[allocation.side],
		allocation.count,
		allocation.role,
		S.base_owner[allocation.base] === allocation.side
			? allocation.base
			: `${cs.SIDE_NAME[allocation.side]} reserve (${allocation.base} changed hands)`,
		tostring(allocation.slot_group),
		tostring(allocation.registered_group),
		reason,
	);
	allocations.delete(allocation.id);
	if (allocation.on_reverted !== undefined) allocation.on_reverted(reason);
	return true;
}

function evaluate(allocation: AircraftAllocation, reason: string): void {
	if (allocation.reverted || !allocation.closed) return;
	if (allocation.attempts.length === 0) return;
	let proven = true;
	for (const attempt of allocation.attempts) {
		// Still unresolved: decide nothing. The task stays ASSIGNED and unretried.
		if (attempt.resolution === "pending") return;
		if (
			attempt.resolution !== "failed_no_creation" &&
			attempt.resolution !== "cancelled"
		)
			// One member of a multi-group package exists: a partial package never refunds the whole.
			proven = false;
	}
	if (proven) {
		revert(allocation, reason);
		return;
	}
	allocations.delete(allocation.id);
}

// ── submission / settlement ──────────────────────────────────────────────────────────────────

/**
 * Called by spawn_queue.drain BEFORE the real API, so a synchronous BIRTH is correlated.
 * Returns undefined for untracked items and for any item whose attempt is already settled —
 * a settled attempt is never re-submitted.
 */
export function prepare_submission(
	item: SpawnItem,
): AircraftAttempt | undefined {
	const id = item.attempt_id;
	if (id === undefined) return undefined;
	const attempt = attempts.get(id);
	if (attempt === undefined || attempt.resolution !== "pending")
		return undefined;
	attempt.submitted = true;
	attempt.birth_seen = false;
	arm(attempt);
	return attempt;
}

/**
 * Called by spawn_queue.drain with what the real API did. Idempotent: a second result for the
 * same attempt is counted and ignored, so repeated reconciliation cannot double-refund.
 */
export function settle_submission(
	attempt: AircraftAttempt | undefined,
	outcome: AttemptOutcome,
	group?: Group,
	detail?: string,
): void {
	if (attempt === undefined) return;
	if (attempt.resolution !== "pending") {
		duplicateSettlements += 1;
		cs.dbg(
			"lifecycle",
			"attempt #%d duplicate result %s ignored (already %s)",
			attempt.id,
			outcome,
			attempt.resolution,
		);
		return;
	}
	attempt.outcome = outcome;
	attempt.detail = detail;
	if (outcome === "returned") {
		const [ok, units] = pcall(() => group?.getUnits());
		if (!ok || units === undefined) {
			attempt.resolution = "created_unverified";
			attempt.detail = `unit query failed: ${tostring(units)}`;
		} else {
			attempt.observed_units = units.length;
			attempt.resolution =
				units.length >= attempt.expected_units.length
					? "created"
					: "created_partial";
		}
	} else {
		const [queryOk, visible] = pcall(
			() => Group.getByName(attempt.group_name) !== undefined,
		);
		if (!queryOk) {
			attempt.resolution = "ambiguous";
			attempt.detail = `group query failed: ${tostring(visible)}`;
		} else if (attempt.birth_seen || visible === true) {
			attempt.resolution = "ambiguous";
			attempt.detail = attempt.birth_seen
				? "birth observed before the failure"
				: "group present after the failure";
		} else attempt.resolution = "failed_no_creation";
	}
	disarm(attempt);
	if (attempt.resolution === "ambiguous") ambiguousAttempts += 1;
	cs.dbg(
		"lifecycle",
		"attempt #%d group=%s outcome=%s birth=%s units=%s -> %s (%s)",
		attempt.id,
		attempt.group_name,
		outcome,
		tostring(attempt.birth_seen),
		tostring(attempt.observed_units),
		attempt.resolution,
		tostring(attempt.detail),
	);
	if (attempt.resolution === "created") attempts.delete(attempt.id);
	const allocation =
		attempt.allocation_id !== undefined
			? allocations.get(attempt.allocation_id)
			: undefined;
	if (allocation !== undefined)
		evaluate(allocation, `attempt #${attempt.id} ${attempt.resolution}`);
}

// ── cancellation ─────────────────────────────────────────────────────────────────────────────

/**
 * Stops a still-queued spawn from ever reaching DCS and reverses its allocation. Refuses once the
 * real API has been called: at that point only settle_submission may decide the outcome.
 */
export function cancel_attempt(
	attempt: AircraftAttempt,
	reason: string,
): boolean {
	if (attempt.resolution !== "pending" || attempt.submitted) return false;
	attempt.cancelled = true;
	attempt.resolution = "cancelled";
	attempt.detail = reason;
	disarm(attempt);
	cs.dbg(
		"lifecycle",
		"attempt #%d group=%s CANCELLED before drain (%s)",
		attempt.id,
		attempt.group_name,
		reason,
	);
	const allocation =
		attempt.allocation_id !== undefined
			? allocations.get(attempt.allocation_id)
			: undefined;
	if (allocation !== undefined) evaluate(allocation, reason);
	return true;
}

/** Cancels the attempt behind a queued item. No-op for untracked (non-aircraft) items. */
export function cancel_item(item: SpawnItem, reason: string): boolean {
	const id = item.attempt_id;
	if (id === undefined) return false;
	const attempt = attempts.get(id);
	if (attempt === undefined) return false;
	return cancel_attempt(attempt, reason);
}

/** spawn_queue.drain asks this before spending an API call on a queued item. */
export function is_cancelled(item: SpawnItem): boolean {
	const id = item.attempt_id;
	if (id === undefined) return false;
	return attempts.get(id)?.cancelled === true;
}

/**
 * Schedules a callback owned by one request. Fenced twice: by the generation (a re-injection) and
 * by that single attempt's own cancel flag, which the generation check cannot express.
 */
export function schedule_for(
	attempt: AircraftAttempt | undefined,
	delay: number,
	callback: (this: void) => void,
): void {
	if (attempt === undefined) return;
	const own = attempt.generation;
	timer.scheduleFunction(
		() => {
			if (generation() !== own) return undefined;
			if (attempt.cancelled) return undefined;
			pcall(callback);
			return undefined;
		},
		undefined,
		timer.getTime() + delay,
	);
}

// ── physical parking stand leases (epic #17 P2) ──────────────────────────────────────────────
// NOT an EECH behaviour. EECH has no parking model at all: aircraft are registered at a keysite
// as a count, and `assign.c:259 get_suitable_registered_group` picks one that already exists.
// Physical stands are a DCS-REPRESENTATION fact, so the numbers here are read from the live
// Airbase object and never invented. No campaign constant is introduced by this section.
//
// Why the allocation owns the lease. Stand selection happens inside the builder, BEFORE
// spawn_queue defers the real coalition.addGroup. Between those two moments the aircraft does not
// exist and DCS knows nothing about the stand we intend to use, so a second builder running in the
// same drain window would pick the same pad. The lease is the provisional overlay that closes that
// window, and it is owned by the allocation so that a reversal (abort_allocation / revert) gives
// the pad back together with the ledger debit and the keysite slot — exactly one owner, one
// rollback path.
//
// MEASURED FACTS this implements (docs/bots/LIVE-PROBE-2026-09-22.md, findings 2-4):
//   * Term_Index is 0-BASED (0..3 on a stock four-pad FARP). The emitted `parking` value maps
//     directly onto it, so stand numbers come from the live terminal set, never from a counter.
//   * `getParking(true)` does NOT reflect occupancy — 4-of-4 "available" with three pads flagged
//     taken. Occupancy is therefore derived from the per-terminal `TO_AC` boolean only, and a
//     failed parking query is UNKNOWN (see farp_parking.ts), never zero and never unlimited.
//   * A departed aircraft keeps `TO_AC=true` while airborne. A lease is therefore NEVER released
//     because its aircraft took off, and never because a pad "looks empty".
//
// Occupied = (live TO_AC) UNION (our leases). The union covers players, pre-existing/authored
// units and anything else parked at the base that we did not put there: we only ever claim a
// terminal the live airbase reports as free.
//
// HANDOVER, not release. A lease is provisional. Once the leased group is visible in DCS AND the
// live terminal reads TO_AC=true, the live truth already covers that pad, so the overlay entry is
// dropped — the stand stays occupied, the union is unchanged, and the registry does not grow
// without bound. The only other drop is a lease whose group HAS existed and is now gone from DCS
// entirely: it holds nothing physical, and TO_AC alone then describes the pad. Retirement /
// recovery settlement is P3 and is deliberately not implemented here.

/** One live parking terminal, as read from `Airbase.getParking()`. */
export interface TerminalSpot {
	/** DCS `Term_Index`, 0-based. */
	index: number;
	/** DCS `TO_AC`: an aircraft occupies this terminal right now. */
	occupied: boolean;
}

interface StandLease {
	base: string;
	index: number;
	group_name: string;
	unit_name: string;
	generation: number;
	allocation_id?: number;
	/** True once the leased group has been seen to exist in DCS at least once. */
	materialised: boolean;
}

const leasesByBase = new Map<string, Map<number, StandLease>>();

function baseLeases(base: string): Map<number, StandLease> {
	const existing = leasesByBase.get(base);
	if (existing !== undefined) return existing;
	const created = new Map<number, StandLease>();
	leasesByBase.set(base, created);
	return created;
}

/**
 * Drops the overlay entries the live airbase now describes on its own, so the union of
 * TO_AC-occupied and leased stands stays exact without the registry growing for ever. Never frees
 * a stand whose aircraft merely took off: TO_AC stays true across a departure (probe finding 4).
 */
function sweepLeases(base: string, terminals: TerminalSpot[]): void {
	const held = leasesByBase.get(base);
	if (held === undefined) return;
	const live = new Map<number, boolean>();
	for (const terminal of terminals) live.set(terminal.index, terminal.occupied);
	const drop: number[] = [];
	for (const [index, lease] of held) {
		if (lease.generation !== generation()) {
			drop.push(index);
			continue;
		}
		const [ok, exists] = pcall(
			() => Group.getByName(lease.group_name) !== undefined,
		);
		// Query failed: UNKNOWN. Keep the lease — releasing on a failed query would hand a pad to
		// a second group while the first may well be sitting on it.
		if (!ok) continue;
		if (exists === true) {
			lease.materialised = true;
			// Live truth has taken over this pad. The overlay steps aside; the pad stays occupied.
			if (live.get(index) === true) drop.push(index);
			continue;
		}
		// Still queued and undrained: the whole point of the lease. Hold it.
		if (!lease.materialised) continue;
		// Existed, and is gone from DCS. The lease holds nothing physical; TO_AC alone now
		// describes the pad.
		drop.push(index);
	}
	for (const index of drop) held.delete(index);
}

/**
 * Atomically leases one distinct real terminal per unit, all or nothing. Returns the claimed
 * `Term_Index` values in ascending order, or undefined when the base cannot seat the whole group
 * right now — the caller must then fail the launch rather than stack aircraft on one pad.
 *
 * `terminals` is the live terminal set; this function never assumes what it contains.
 */
export function reserve_stands(
	base: string,
	groupName: string,
	unitNames: string[],
	terminals: TerminalSpot[],
): number[] | undefined {
	sweepLeases(base, terminals);
	const held = baseLeases(base);
	const free: number[] = [];
	for (const terminal of terminals)
		if (!terminal.occupied && !held.has(terminal.index))
			free.push(terminal.index);
	free.sort((left, right) => left - right);
	if (free.length < unitNames.length) {
		cs.dbg(
			"lifecycle",
			"stand lease REFUSED at %s for %s: %d requested, %d free of %d terminals",
			base,
			groupName,
			unitNames.length,
			free.length,
			terminals.length,
		);
		return undefined;
	}
	const allocation = currentScope();
	const claimed: number[] = [];
	for (let i = 0; i < unitNames.length; i += 1) {
		const index = free[i];
		held.set(index, {
			base,
			index,
			group_name: groupName,
			unit_name: unitNames[i],
			generation: generation(),
			allocation_id: allocation?.id,
			materialised: false,
		});
		claimed.push(index);
	}
	cs.dbg(
		"lifecycle",
		"stand lease at %s for %s: Term_Index %s (alloc=%s, %d of %d terminals now claimed)",
		base,
		groupName,
		table.concat(
			claimed.map((index) => tostring(index)),
			",",
		),
		tostring(allocation?.id),
		held.size,
		terminals.length,
	);
	return claimed;
}

function releaseWhere(
	match: (this: void, lease: StandLease) => boolean,
	reason: string,
): number {
	let released = 0;
	for (const [base, held] of leasesByBase) {
		const drop: number[] = [];
		for (const [index, lease] of held) if (match(lease)) drop.push(index);
		for (const index of drop) {
			const lease = held.get(index);
			held.delete(index);
			released += 1;
			cs.dbg(
				"lifecycle",
				"stand Term_Index %d at %s released from %s (%s)",
				index,
				base,
				tostring(lease?.group_name),
				reason,
			);
		}
	}
	return released;
}

/** Rolls back only the stands this allocation claimed. Used by the reversal path. */
export function release_stands_for_allocation(
	allocationId: number,
	reason: string,
): number {
	return releaseWhere((lease) => lease.allocation_id === allocationId, reason);
}

/**
 * Releases every stand held on behalf of one group. Exported for the P3 retirement/recovery
 * settlement, which owns "this airframe is finished with its pad"; nothing in P2 calls it on a
 * takeoff, a landing or an apparently empty pad.
 */
export function release_stands_for_group(
	groupName: string,
	reason: string,
): number {
	return releaseWhere((lease) => lease.group_name === groupName, reason);
}

/**
 * Releases the stand held for ONE airframe. A pad is per aircraft, and P3 retires aircraft one at
 * a time, so a wingman still flying keeps its own pad claimed until it too is settled.
 */
export function release_stands_for_unit(
	unitName: string,
	reason: string,
): number {
	return releaseWhere((lease) => lease.unit_name === unitName, reason);
}

/** Read-only: the Term_Index values this module currently holds at `base`, ascending. */
export function leased_stands(base: string): number[] {
	const held = leasesByBase.get(base);
	const out: number[] = [];
	if (held === undefined) return out;
	for (const [index] of held) out.push(index);
	out.sort((left, right) => left - right);
	return out;
}

/** Read-only: which group holds `index` at `base`, if anyone. */
export function stand_holder(base: string, index: number): string | undefined {
	return leasesByBase.get(base)?.get(index)?.group_name;
}

// ── sortie recovery / loss settlement (epic #17 P3) ──────────────────────────────────────────
//
// EECH SOURCE for the SHAPE of this accounting (no constant is introduced anywhere below):
//   force.c:211-243   add_to_force_info (force_en, new_en)       — ONE entity: current++, reserve--
//   force.c:249-271   remove_from_force_info (force_en, new_en)  — ONE entity: current--, and the
//                                                                  loss stat is added for THAT one
//                                                                  entity (force.c:258)
//   force.c:278-300   replace_into_force_info (force_en, new_en) — ONE entity: reserve++ (:297)
//   hc_dstry.c:343-346 / fw_dstry.c:332-335 — the aircraft destructor RETURNS BEFORE it touches
//                                             force info at all when the entity is no longer
//                                             INT_TYPE_ALIVE.
//
// EECH's entire reserve economy is per AIRFRAME: every one of those three functions takes a single
// `entity *`. The port had drifted to per-GROUP settlement — one member's landing credited every
// unit `Group:getUnits()` returned and destroyed the whole group — which is what let the measured
// sequence at docs/bots/LIVE-PROBE-2026-09-22.md finding 7 credit a CRASHED airframe as a recovery:
//
//   t=1953 RUNWAY_TOUCH Heli-CAS-1-2055-1   t=1954 CRASH Heli-CAS-1-2055-1 place=nil
//   t=1955 RUNWAY_TOUCH Heli-CAS-1-2055-2   t=1956 LAND  Heli-CAS-1-2055-2 place=FARP(id=3)
//
// Settlement is therefore per airframe here, exactly once, and it is driven by the ALLOCATION's
// recorded role and expected unit names (P1) rather than by re-deriving a role from the group-name
// prefix. `supply.classify_role` survives only as the fallback for groups that have not yet been
// brought under `begin_allocation` (P4 closes that).
//
// PORT PROXY, unchanged in substance (see supply.ts's header): shipped EECH has ZERO callers of
// replace_into_force_info, so "landing returns hardware to the reserve" is the port's
// reconstruction of the design intent, not literal EECH behaviour. P3 does not widen that proxy —
// it narrows it, by requiring evidence before any credit happens.
//
// MEASURED DCS FACTS this implements (docs/bots/LIVE-PROBE-2026-09-22.md findings 6-7,
// dcs-bugs/aircraft-lifecycle/probe-events-pre-p2.txt, 219 events / 9 landings):
//   * S_EVENT_LAND carries a real `place` with getName()/getID()/getDesc().category at both
//     airdromes (Kutaisi id=25 cat=0) and authored FARPs (FARP-... id=3 cat=1). The landing site
//     is therefore READ, never guessed — the old "nearest friendly base anywhere on the map"
//     positional proxy is retired.
//   * CRASH (5) and DEAD (8) carry place=nil. A loss has no site; a missing site is never a
//     landing.
//   * RUNWAY_TOUCH (55) fires for a crash as well as for a recovery, so runway contact is not
//     evidence of recovery and is not consumed here at all.
//
// UNKNOWN IS NOT RECOVERED (the P1 rule, mirrored). A landing with no readable friendly site is
// not credited and not retired; the airframe simply stays outbound and remains visible. Crediting
// on weak evidence invents stock permanently, which is strictly worse than carrying a known
// unknown — the same trade ADR 0009 made for refunds.

export type MemberState =
	| "outbound"
	| "returned"
	| "lost"
	| "retired"
	| "resolved";

export type LandingVerdict =
	| "recovered"
	| "player"
	| "stale"
	| "no_site"
	| "unknown_site"
	| "hostile_site"
	| "mission_landing"
	| "already_settled"
	| "confirmed_lost"
	| "budget_exhausted"
	| "unclassified"
	| "retired_unit";

export interface SortieMember {
	unit_name: string;
	state: MemberState;
	/** True once this airframe has been observed to exist in DCS at least once. */
	seen: boolean;
	/** Campaign base this airframe was recovered at, once it has been. */
	site?: string;
	detail?: string;
}

export interface SortieFacts {
	group_name: string;
	side: Side;
	/**
	 * Reserve role taken from the ALLOCATION. Undefined means "this sortie credits nothing" —
	 * it is still tracked so its stands and launch slot are released on retirement.
	 */
	role?: ReserveRole;
	/** Base whose ledger was debited. Diagnostics only: a credit goes to the RECOVERY site. */
	debit_base?: string;
	unit_names: string[];
	/** Hard ceiling on airframes this sortie may ever credit back. Defaults to #unit_names. */
	budget?: number;
	task_type?: string;
	target_base?: string;
	/** True when the facts came from a P1 allocation rather than the group-name fallback. */
	tracked: boolean;
}

interface Sortie {
	group_name: string;
	generation: number;
	side: Side;
	role?: ReserveRole;
	debit_base?: string;
	budget: number;
	task_type?: string;
	target_base?: string;
	tracked: boolean;
	members: SortieMember[];
	credited: number;
	slot_released: boolean;
	retired: boolean;
}

export interface LandingEvidence {
	group_name: string;
	unit_name: string;
	side: Side;
	/** `event.place`, exactly as DCS delivered it. Absent on an off-field landing. */
	place?: Airbase;
	/** True when the landing airframe is under player control. */
	player: boolean;
	/** Currently existing unit names of the group, used ONLY to seed an untracked sortie. */
	member_names?: string[];
	/**
	 * Delay before the landed airframe is retired from the world. Owned and passed in by the
	 * caller (supply.LANDED_GROUP_CLEANUP_DELAY_SECONDS) so no cadence is defined in this module.
	 */
	cleanup_delay: number;
}

export interface LandingResult {
	verdict: LandingVerdict;
	/** Campaign base the landing was resolved to, when one could be resolved. */
	site?: string;
	role?: ReserveRole;
	detail?: string;
}

let sorties = new Map<string, Sortie>();
/** unit name -> group name, so a loss event needs no live getGroup(). */
let memberOwner = new Map<string, string>();
/** Task facts snapshotted BEFORE cs.clear_task() drops them. */
let taskFacts = new Map<string, { task_type?: string; target_base?: string }>();
let sortieGeneration = generation();
let creditedAirframes = 0;
let refusedCredits = 0;
let confirmedLosses = 0;
let virtualRetirements = 0;
let virtualCredits = 0;
let virtualAbandons = 0;

/**
 * `S._recycled` is shared. Everything written by the settlement path lives under `unit:`, so the
 * per-airframe "credited exactly once" guard can never be satisfied or defeated by a key some
 * other module wrote (see the header). Any future group-keyed user must pick its own prefix.
 */
function recycledKey(unitName: string): string {
	return `unit:${unitName}`;
}

/**
 * Every registry below belongs to ONE campaign generation. A re-injection replaces the whole
 * state table, so the old campaign's sorties must never settle into the new one's ledger; they
 * are dropped wholesale rather than fenced record by record, which also bounds growth.
 */
function sortieRegistry(): Map<string, Sortie> {
	if (sortieGeneration !== generation()) {
		sorties = new Map<string, Sortie>();
		memberOwner = new Map<string, string>();
		taskFacts = new Map<string, { task_type?: string; target_base?: string }>();
		sortieGeneration = generation();
	}
	return sorties;
}

function memberOf(sortie: Sortie, unitName: string): SortieMember | undefined {
	for (const member of sortie.members)
		if (member.unit_name === unitName) return member;
	return undefined;
}

function terminal(state: MemberState): boolean {
	return state === "lost" || state === "retired" || state === "resolved";
}

/** Snapshots the task facts a recovery decision needs, so they survive `cs.clear_task()`. */
export function note_task(
	groupName: string,
	task: { task_type?: string; target_base?: string } | undefined,
): void {
	if (task === undefined) return;
	const facts = {
		task_type: task.task_type,
		target_base: task.target_base,
	};
	taskFacts.set(groupName, facts);
	const sortie = sortieRegistry().get(groupName);
	if (sortie !== undefined) {
		if (sortie.task_type === undefined) sortie.task_type = facts.task_type;
		if (sortie.target_base === undefined)
			sortie.target_base = facts.target_base;
	}
}

/**
 * Records what one spawned GROUP is expected to bring home, from the allocation that paid for it.
 * Re-registering the same group name replaces the record: a name reused by a later sortie is a
 * new sortie, never a continuation of a settled one.
 */
export function register_sortie(facts: SortieFacts): void {
	const registry = sortieRegistry();
	const members: SortieMember[] = [];
	const seenNames: Record<string, boolean> = {};
	for (const name of facts.unit_names) {
		if (seenNames[name]) continue;
		seenNames[name] = true;
		members.push({ unit_name: name, state: "outbound", seen: false });
	}
	if (members.length === 0) return;
	const snapshot = taskFacts.get(facts.group_name);
	const sortie: Sortie = {
		group_name: facts.group_name,
		generation: generation(),
		side: facts.side,
		role: facts.role,
		debit_base: facts.debit_base,
		// The ceiling is what the allocation paid for. Every current caller debits exactly one
		// airframe per expected unit, so the two agree; taking the minimum keeps that true even
		// if a future caller debits fewer.
		budget: math.min(facts.budget ?? members.length, members.length),
		task_type: facts.task_type ?? snapshot?.task_type,
		target_base: facts.target_base ?? snapshot?.target_base,
		tracked: facts.tracked,
		members,
		credited: 0,
		slot_released: false,
		retired: false,
	};
	registry.set(sortie.group_name, sortie);
	for (const member of members)
		memberOwner.set(member.unit_name, sortie.group_name);
	cs.dbg(
		"lifecycle",
		"sortie %s registered: %s %s x%d from %s (tracked=%s target=%s)",
		sortie.group_name,
		cs.SIDE_NAME[sortie.side],
		tostring(sortie.role),
		sortie.budget,
		tostring(sortie.debit_base),
		tostring(sortie.tracked),
		tostring(sortie.target_base),
	);
}

/** Forgets a sortie entirely. Only for a group PROVEN never to have reached DCS. */
export function drop_sortie(groupName: string): void {
	const registry = sortieRegistry();
	const sortie = registry.get(groupName);
	if (sortie === undefined) return;
	for (const member of sortie.members) {
		if (memberOwner.get(member.unit_name) === groupName)
			memberOwner.delete(member.unit_name);
	}
	registry.delete(groupName);
	taskFacts.delete(groupName);
}

/** Read-only view of one sortie, for tests and diagnostics. */
export function sortie_of(groupName: string): Sortie | undefined {
	return sortieRegistry().get(groupName);
}

/** Read-only: the settlement state of one airframe. */
export function member_state(unitName: string): MemberState | undefined {
	const groupName = memberOwner.get(unitName);
	if (groupName === undefined) return undefined;
	const sortie = sortieRegistry().get(groupName);
	if (sortie === undefined) return undefined;
	return memberOf(sortie, unitName)?.state;
}

/**
 * True when THIS module took the airframe out of the world as part of a completed settlement.
 * Its disappearance is bookkeeping, not a combat loss: mirrors the aircraft destructor's own
 * `if (!INT_TYPE_ALIVE) return;` gate (hc_dstry.c:343-346, fw_dstry.c:332-335), which is exactly
 * EECH declining to charge a loss for removing something that is no longer a live fielded asset.
 */
export function is_retired_unit(unitName: string): boolean {
	return member_state(unitName) === "retired";
}

/** True when the whole group was retired by this module. */
export function is_retired_group(groupName: string): boolean {
	return sortieRegistry().get(groupName)?.retired === true;
}

// ── landing-site identity ────────────────────────────────────────────────────────────────────

let siteIdIndex: Map<string, string> | undefined;
let siteIdGeneration = -1;

/**
 * Airbase id -> campaign base name, built once per generation. Our base names ARE DCS airbase
 * names (every builder resolves its home with `Airbase.getByName(baseName)`), so the name match
 * below is the primary route; the id index is the documented fallback for a site whose reported
 * name has drifted from the registry key.
 */
function siteIndex(): Map<string, string> {
	if (siteIdIndex !== undefined && siteIdGeneration === generation())
		return siteIdIndex;
	const index = new Map<string, string>();
	for (const [name] of pairs(S.base_owner)) {
		const [ok, base] = pcall(() => Airbase.getByName(name));
		if (!ok || base === undefined) continue;
		const [idOk, id] = pcall(() => base.getID());
		if (idOk && id !== undefined) index.set(tostring(id), name);
	}
	siteIdIndex = index;
	siteIdGeneration = generation();
	return index;
}

/**
 * Resolves `event.place` to a campaign base name. Returns undefined when the event carried no
 * place at all (an off-field landing, and every CRASH/DEAD) or when the place is not a site this
 * campaign knows — neither is evidence of a recovery.
 */
export function resolve_site(place: Airbase | undefined): string | undefined {
	if (place === undefined) return undefined;
	const [nameOk, name] = pcall(() => place.getName());
	if (nameOk && name !== undefined && S.base_owner[name] !== undefined)
		return name;
	const [idOk, id] = pcall(() => place.getID());
	if (!idOk || id === undefined) return undefined;
	return siteIndex().get(tostring(id));
}

// ── settlement ───────────────────────────────────────────────────────────────────────────────

function unitExists(unitName: string): boolean | undefined {
	const [ok, unit] = pcall(() => Unit.getByName(unitName));
	// A failed query is UNKNOWN, never "gone": the P1 rule, applied to the other direction.
	if (!ok) return undefined;
	if (unit === undefined) return false;
	const [aliveOk, alive] = pcall(() => unit.isExist());
	if (!aliveOk) return undefined;
	return alive === true;
}

function unitIsPlayer(unitName: string): boolean {
	const [ok, unit] = pcall(() => Unit.getByName(unitName));
	if (!ok || unit === undefined) return false;
	const [nameOk, playerName] = pcall(() => unit.getPlayerName?.());
	return nameOk && playerName !== undefined;
}

/**
 * Re-reads every member that is still outbound. An airframe that HAS been seen in DCS and is now
 * gone with no loss event is resolved (no credit, no loss); one that was never seen, or whose
 * query failed, stays outbound — a transiently missing unit is not a dead one.
 */
function refreshMembers(sortie: Sortie): void {
	for (const member of sortie.members) {
		if (terminal(member.state)) continue;
		const exists = unitExists(member.unit_name);
		if (exists === undefined) continue;
		if (exists) {
			member.seen = true;
			continue;
		}
		if (!member.seen) continue;
		if (member.state === "returned") continue;
		member.state = "resolved";
		member.detail = "no longer present in DCS, no loss event";
		cs.dbg(
			"lifecycle",
			"sortie %s member %s vanished without a loss event — resolved, not credited",
			sortie.group_name,
			member.unit_name,
		);
	}
}

/** Gives back the launch slot and any remaining stands once nothing is outstanding. */
function finishSortie(sortie: Sortie, reason: string): void {
	for (const member of sortie.members) if (!terminal(member.state)) return;
	if (sortie.retired) return;
	sortie.retired = true;
	const keysite = require<typeof import("./keysite")>("keysite");
	if (!sortie.slot_released) {
		sortie.slot_released = true;
		keysite.release_slot(sortie.group_name);
	}
	release_stands_for_group(sortie.group_name, `sortie settled (${reason})`);
	cs.dbg(
		"lifecycle",
		"sortie %s SETTLED (%s): %d of %d airframes credited",
		sortie.group_name,
		reason,
		sortie.credited,
		sortie.budget,
	);
}

/**
 * Credits exactly one airframe back to the reserve, at the base it actually recovered at.
 * Capped by the sortie's budget so the same sortie can never return more hardware than it took.
 */
function creditAirframe(sortie: Sortie, member: SortieMember): boolean {
	if (sortie.role === undefined) return false;
	if (sortie.credited >= sortie.budget) {
		refusedCredits += 1;
		cs.dbg(
			"lifecycle",
			"sortie %s refused a credit for %s: budget %d already exhausted",
			sortie.group_name,
			member.unit_name,
			sortie.budget,
		);
		return false;
	}
	const guard = recycledKey(member.unit_name);
	if (S._recycled[guard] === true) {
		refusedCredits += 1;
		return false;
	}
	const supply = require<typeof import("./supply")>("supply");
	const site = member.site;
	sortie.credited += 1;
	creditedAirframes += 1;
	S._recycled[guard] = true;
	// The recovery base changing hands between the landing and the retirement would otherwise
	// hand the airframe to the captor (base_ledger travels with the base, keysite.ts:916-927).
	if (site !== undefined && S.base_owner[site] === sortie.side)
		supply.recycle_base(site, sortie.role, 1);
	else supply.recycle_side(sortie.side, sortie.role, 1);
	return true;
}

/**
 * Takes ONE recovered airframe out of the world and credits it in the same step, so the same
 * aircraft can never be both parked in DCS and counted as idle stock. Every precondition is
 * re-checked here, not at landing time: generation, the sortie still being the current one for
 * that group name, the member still being the one that landed, and player control.
 */
function retireMember(sortie: Sortie, unitName: string): void {
	if (sortie.generation !== generation()) return;
	if (sortieRegistry().get(sortie.group_name) !== sortie) return;
	const member = memberOf(sortie, unitName);
	if (member === undefined || member.state !== "returned") return;
	refreshMembers(sortie);
	if (member.state !== "returned") return;
	if (unitIsPlayer(unitName)) {
		// Players are first-class: a human in the cockpit is never despawned, and an airframe we
		// did not remove is never counted as returned stock.
		member.state = "resolved";
		member.detail = "player took control before cleanup";
		cs.dbg(
			"lifecycle",
			"sortie %s member %s is player-controlled — no destroy, no credit",
			sortie.group_name,
			unitName,
		);
		finishSortie(sortie, "player takeover");
		return;
	}
	const exists = unitExists(unitName);
	if (exists === undefined) {
		// Unknown: leave it returned and visible. No retry cadence is invented here.
		cs.dbg(
			"lifecycle",
			"sortie %s member %s: existence query failed at retirement — left unsettled",
			sortie.group_name,
			unitName,
		);
		return;
	}
	if (exists) {
		const [ok, err] = pcall(() => Unit.getByName(unitName)?.destroy());
		if (!ok) {
			cs.dbg(
				"lifecycle",
				"sortie %s member %s destroy() failed (%s) — not credited",
				sortie.group_name,
				unitName,
				tostring(err),
			);
			return;
		}
	}
	member.state = "retired";
	release_stands_for_unit(unitName, "airframe retired after recovery");
	const credited = creditAirframe(sortie, member);
	cs.dbg(
		"lifecycle",
		"sortie %s member %s RETIRED at %s (credited=%s, %d/%d)",
		sortie.group_name,
		unitName,
		tostring(member.site),
		tostring(credited),
		sortie.credited,
		sortie.budget,
	);
	finishSortie(sortie, "recovery");
}

/**
 * Builds the fallback record for a group that has not been brought under `begin_allocation`.
 * The role comes from `supply.classify_role`'s name prefix, which is exactly the guess P3 exists
 * to replace — it survives only until P4 puts the remaining callers behind an allocation.
 */
function fallbackSortie(evidence: LandingEvidence): Sortie | undefined {
	const supply = require<typeof import("./supply")>("supply");
	const [ok, role] = pcall(() => supply.classify_role(evidence.group_name));
	const names: string[] = [];
	const seenNames: Record<string, boolean> = {};
	for (const name of evidence.member_names ?? []) {
		if (!seenNames[name]) {
			seenNames[name] = true;
			names.push(name);
		}
	}
	if (!seenNames[evidence.unit_name]) names.push(evidence.unit_name);
	const snapshot = taskFacts.get(evidence.group_name);
	const task = cs.get_task(evidence.group_name);
	register_sortie({
		group_name: evidence.group_name,
		side: evidence.side,
		role: ok ? role : undefined,
		debit_base: S.group_launch_base[evidence.group_name],
		unit_names: names,
		task_type: task?.task_type ?? snapshot?.task_type,
		target_base: task?.target_base ?? snapshot?.target_base,
		tracked: false,
	});
	return sortieRegistry().get(evidence.group_name);
}

/**
 * Evaluates one S_EVENT_LAND. A landing STARTS an evaluation; it is not itself a recovery.
 * Nothing is credited, released or destroyed unless the airframe genuinely came back to a usable
 * friendly site that it was not sent to in the first place.
 */
export function settle_landing(evidence: LandingEvidence): LandingResult {
	if (evidence.player) return { verdict: "player" };
	if (is_retired_unit(evidence.unit_name)) return { verdict: "retired_unit" };
	const registry = sortieRegistry();
	let sortie = registry.get(evidence.group_name);
	if (sortie === undefined) sortie = fallbackSortie(evidence);
	if (sortie === undefined) return { verdict: "unknown_site" };
	if (sortie.generation !== generation()) return { verdict: "stale" };
	let member = memberOf(sortie, evidence.unit_name);
	if (member === undefined) {
		// A member the allocation did not expect (a replacement slot, a renamed unit). Track it,
		// but it can only ever be credited inside the sortie's existing budget.
		member = { unit_name: evidence.unit_name, state: "outbound", seen: true };
		sortie.members.push(member);
		memberOwner.set(evidence.unit_name, sortie.group_name);
	}
	member.seen = true;
	if (member.state === "lost")
		return { verdict: "confirmed_lost", role: sortie.role };
	if (terminal(member.state) || member.state === "returned")
		return { verdict: "already_settled", role: sortie.role };

	const site = resolve_site(evidence.place);
	if (evidence.place === undefined)
		return { verdict: "no_site", role: sortie.role };
	if (site === undefined) return { verdict: "unknown_site", role: sortie.role };
	if (S.base_owner[site] !== sortie.side)
		return { verdict: "hostile_site", site, role: sortie.role };
	if (sortie.target_base !== undefined && sortie.target_base === site)
		// The aircraft is AT its objective: a troop insertion putting boots down, a supply flight
		// delivering. That is the task being carried out, not the airframe coming home.
		return { verdict: "mission_landing", site, role: sortie.role };
	if (sortie.role === undefined) {
		// No allocation and no name-prefix role: there is nothing to credit and nothing this
		// module can claim to own. Give the launch slot back — which is exactly what the pre-P3
		// handler did for an unclassified group — and leave the aircraft alone. Retiring an
		// airframe we cannot account for would be destroying something we do not understand.
		resolve_sortie(
			sortie.group_name,
			"landed, no reserve role to settle against",
		);
		return { verdict: "unclassified", site };
	}
	if (sortie.credited >= sortie.budget) {
		refusedCredits += 1;
		return { verdict: "budget_exhausted", site, role: sortie.role };
	}

	member.state = "returned";
	member.site = site;
	schedule_member_retirement(sortie, member.unit_name, evidence.cleanup_delay);
	cs.dbg(
		"lifecycle",
		"sortie %s member %s recovered at %s (role=%s) — retirement in %ds",
		sortie.group_name,
		member.unit_name,
		site,
		tostring(sortie.role),
		evidence.cleanup_delay,
	);
	return { verdict: "recovered", site, role: sortie.role };
}

function schedule_member_retirement(
	sortie: Sortie,
	unitName: string,
	delay: number,
): void {
	const own = generation();
	timer.scheduleFunction(
		() => {
			if (generation() !== own) return undefined;
			pcall(() => retireMember(sortie, unitName));
			return undefined;
		},
		undefined,
		timer.getTime() + delay,
	);
}

/**
 * Records a confirmed loss (S_EVENT_CRASH / S_EVENT_DEAD). A lost airframe can never be credited,
 * whatever arrives afterwards. Idempotent, and deliberately silent for an airframe THIS module
 * retired — that disappearance is our own cleanup, not a combat loss.
 */
export function note_loss(unitName: string, groupName?: string): boolean {
	const registry = sortieRegistry();
	const owner = groupName ?? memberOwner.get(unitName);
	if (owner === undefined) return false;
	const sortie = registry.get(owner);
	if (sortie === undefined) return false;
	if (sortie.generation !== generation()) return false;
	const member = memberOf(sortie, unitName);
	if (member === undefined) return false;
	if (member.state === "retired" || member.state === "lost") return false;
	const wasReturned = member.state === "returned";
	member.state = "lost";
	member.detail = wasReturned
		? "lost after touching down, before retirement"
		: "confirmed loss";
	confirmedLosses += 1;
	cs.dbg(
		"lifecycle",
		"sortie %s member %s LOST%s — no reserve credit",
		sortie.group_name,
		unitName,
		wasReturned ? " after landing" : "",
	);
	release_stands_for_unit(unitName, "airframe lost");
	finishSortie(sortie, "loss");
	return true;
}

/**
 * Explicitly finishes a sortie that will never resolve on its own — a task expiry, a forced
 * despawn. Credits nothing: an airframe with no recovery evidence is not recovered. Safe to call
 * after a settlement has already happened, which is the point.
 */
export function resolve_sortie(groupName: string, reason: string): boolean {
	const sortie = sortieRegistry().get(groupName);
	if (sortie === undefined) return false;
	if (sortie.generation !== generation()) return false;
	let changed = false;
	for (const member of sortie.members) {
		if (terminal(member.state)) continue;
		member.state = "resolved";
		member.detail = reason;
		changed = true;
	}
	finishSortie(sortie, reason);
	return changed;
}

/**
 * How a TIMER ended a sortie, when the aircraft itself never told us (P4).
 *
 *   `recycled`  — the timer stands in for an RTB: every surviving airframe is taken out of the
 *                 world and returned to the reserve. This is what reaction's CAP expiry, the BDA
 *                 loiter and supply_flight's route backstop have always done; the only change is
 *                 that they now do it through the one per-airframe path, so a flight that landed
 *                 first cannot also be credited by its own recovery.
 *   `abandoned` — the timer gives up: nothing is destroyed and NOTHING is credited. troop's
 *                 insertion TTL, which has never returned its `transport` debit. Whether that
 *                 one-way leak is right is a deferred question with no EECH citation yet
 *                 (sprint 04); this outcome preserves it exactly rather than deciding it.
 */
export type VirtualOutcome = "recycled" | "abandoned";

/**
 * VIRTUAL RETIREMENT — a DCS proxy, not an EECH behaviour. See the module header.
 *
 * Settles a sortie on a clock instead of on evidence, and is the SOLE owner of the reserve
 * credit, the stand leases and the keysite launch slot while doing so. Returns true when a live
 * record for `groupName` existed and this module therefore owns the cleanup; false when there is
 * none (the launch was reversed before it ever reached DCS, or the record belongs to a previous
 * generation), in which case the caller is still the owner and must do its own cleanup.
 *
 * Players are first-class, including here: a human in the cockpit is never destroyed and never
 * counted as returned stock, exactly as in the recovery path.
 *
 * No credit is invented. An airframe that is already gone, or whose existence query fails, is
 * `resolved` — closed out, never credited. "Unknown is not recovered", the same rule ADR 0009
 * applied to refunds and ADR 0010 to landings.
 */
export function retire_sortie(
	groupName: string,
	reason: string,
	outcome: VirtualOutcome,
): boolean {
	const sortie = sortieRegistry().get(groupName);
	if (sortie === undefined) return false;
	if (sortie.generation !== generation()) return false;
	virtualRetirements += 1;
	for (const member of sortie.members) {
		if (terminal(member.state)) continue;
		if (unitIsPlayer(member.unit_name)) {
			member.state = "resolved";
			member.detail = "player-controlled when the timer fired";
			cs.dbg(
				"lifecycle",
				"sortie %s member %s is player-controlled — virtual retirement destroys and credits nothing",
				groupName,
				member.unit_name,
			);
			continue;
		}
		if (outcome === "abandoned") {
			member.state = "resolved";
			member.detail = reason;
			virtualAbandons += 1;
			continue;
		}
		const exists = unitExists(member.unit_name);
		if (exists !== true) {
			member.state = "resolved";
			member.detail =
				exists === false
					? "already gone when the timer fired"
					: "existence unknown when the timer fired";
			continue;
		}
		const [ok, err] = pcall(() => Unit.getByName(member.unit_name)?.destroy());
		if (!ok) {
			// Could not take it out of the world, so it must not be counted as back in stock:
			// that is exactly the duplicate-airframe hazard the epic forbids.
			member.state = "resolved";
			member.detail = `destroy failed at virtual retirement: ${tostring(err)}`;
			continue;
		}
		member.state = "retired";
		release_stands_for_unit(
			member.unit_name,
			"airframe retired by virtual retirement",
		);
		if (creditAirframe(sortie, member)) virtualCredits += 1;
	}
	finishSortie(sortie, `virtual retirement (${outcome}): ${reason}`);
	return true;
}

/** Read-only: sorties still carrying an airframe whose fate is unknown. */
export function unsettled_sorties(): string[] {
	const out: string[] = [];
	for (const [name, sortie] of sortieRegistry()) {
		if (sortie.retired) continue;
		for (const member of sortie.members) {
			if (!terminal(member.state)) {
				out.push(name);
				break;
			}
		}
	}
	return out;
}

// ── observation (read-only; nothing here is required for correctness) ────────────────────────

export function get_attempt(id?: number): AircraftAttempt | undefined {
	return id === undefined ? undefined : attempts.get(id);
}

export function get_allocation(id?: number): AircraftAllocation | undefined {
	return id === undefined ? undefined : allocations.get(id);
}

/** True while the physical outcome of `id` is genuinely not known yet. */
export function attempt_unresolved(id?: number): boolean {
	if (id === undefined) return false;
	return attempts.get(id)?.resolution === "pending";
}

/** Every attempt that has not been proven one way or the other, including ambiguous ones. */
export function unresolved(): AircraftAttempt[] {
	const out: AircraftAttempt[] = [];
	for (const [, attempt] of attempts) {
		if (attempt.resolution === "pending" || attempt.resolution === "ambiguous")
			out.push(attempt);
	}
	return out;
}

export function stats(): {
	tracked: number;
	open_allocations: number;
	refunded: number;
	ambiguous: number;
	duplicate_results: number;
	leased_stands: number;
	sorties: number;
	credited_airframes: number;
	refused_credits: number;
	confirmed_losses: number;
	unsettled_sorties: number;
	/** Sorties closed by a TIMER rather than by evidence (P4 virtual retirement). */
	virtual_retirements: number;
	/** Airframes credited on the timer proxy alone — a SUBSET of credited_airframes. */
	virtual_credits: number;
	/** Airframes closed out by a timer with no credit at all (troop TTL). */
	virtual_abandons: number;
} {
	let stands = 0;
	for (const [, held] of leasesByBase) stands += held.size;
	return {
		tracked: attempts.size,
		open_allocations: allocations.size,
		refunded: refundedAllocations,
		ambiguous: ambiguousAttempts,
		duplicate_results: duplicateSettlements,
		leased_stands: stands,
		sorties: sortieRegistry().size,
		credited_airframes: creditedAirframes,
		refused_credits: refusedCredits,
		confirmed_losses: confirmedLosses,
		unsettled_sorties: unsettled_sorties().length,
		virtual_retirements: virtualRetirements,
		virtual_credits: virtualCredits,
		virtual_abandons: virtualAbandons,
	};
}
