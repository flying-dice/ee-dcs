// Offline regression harness for the ee-dcs campaign port.
//
// WHAT IS COMPARED, and why it is more than names and ticks.
//   Until 2026-09-21 this harness compared only the timer tick count and the SET of spawned
//   group/static NAMES. That is blind to two whole classes of defect, both of which reached
//   main and both of which this suite passed through green:
//     * ORDERS CHANGED, NAMES DIDN'T — `numericSuffix()` read string.match() without
//       destructuring, so every artillery and secondary group took lateral slot -2 and
//       co-located groups converged on one deployment point instead of dispersing. Same
//       names, same ticks, different destination waypoints.
//     * GENERATOR PRODUCED NOTHING — 12 string.match LuaMultiReturn defects left the SEAD
//       and BAI generators permanently dead. Their orphaned tasks expired before spawning
//       anything, so again: same names, same ticks.
//   So the comparison now also covers, for both durations:
//     - `orders`   : the ordered, duplicate-preserving log of every coalition.addGroup,
//                    coalition.addStaticObject and Controller:setTask/pushTask call, with
//                    route waypoints, task parameters and unit composition. Being a LIST it
//                    carries CALL MULTIPLICITY, which a name set cannot.
//     - `spawn_call_counts`    : per-name spawn call counts (duplicate-spawn regressions).
//     - `task_creations`       : board tasks created, by task type.
//     - `generator_liveness`   : per-generator task counts from a fixture that saturates fog
//                                of war, so a generator that creates zero tasks is a failure
//                                rather than a legitimate quiet pass.
//   Log line count is still NOT compared: the trees emit different env.info() verbosity by
//   design. That is the only deliberately excluded field.
//
// Two legs, in decreasing order of durability:
//
//   1. TYPESCRIPT vs GOLDEN FIXTURE  (always runs)
//      test/golden/baseline-<duration>.json is a frozen snapshot of the LUA baseline's
//      world state, captured from Scripts/ee-dcs/*.lua at its pre-deletion state. Asserting
//      the typescript run against it is what keeps the baseline working as a regression net
//      AFTER the Lua tree is deleted.
//
//   2. LUA vs TYPESCRIPT differential  (runs only while Scripts/ee-dcs/main.lua exists)
//      The live side-by-side comparison. It also re-checks the Lua tree against the golden
//      fixture, so fixture drift is caught while the baseline is still around to arbitrate.
//      Once Scripts/ee-dcs is deleted this leg SKIPS with a message; it never crashes.
//
// Re-recording the golden fixtures (the lua baseline's own answers, from its pinned
// pre-deletion commit 232b9f5 — the tree is NOT restored into the working copy):
//      git archive 232b9f5 Scripts/ee-dcs | tar -x -C <scratch>
//      node packages/ee-mission/test/run-tests.cjs --record-golden <scratch>
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const root = path.resolve(__dirname, "../../..");
const lua = process.env.LUA_BIN || "lua";
const luaTreeEntry = path.join(root, "Scripts", "ee-dcs", "main.lua");
const luaTreePresent = fs.existsSync(luaTreeEntry);

// Overall verdict. Declared up here because run() flips it when a leg exits non-zero.
let ok = true;

function run(file, args) {
	const result = spawnSync(lua, [path.join(__dirname, file), root, ...args], {
		cwd: root,
		encoding: "utf8",
	});
	if (result.error) {
		console.error(
			`Unable to run Lua 5.1. Set LUA_BIN to its executable: ${result.error.message}`,
		);
		process.exit(1);
	}
	if (result.stdout) process.stdout.write(result.stdout);
	if (result.stderr) process.stderr.write(result.stderr);
	// A failing leg no longer aborts the run. campaign-smoke.lua prints SUMMARY_JSON before
	// raising its fixture failures, so continuing lets the order-log diff be reported in the
	// SAME run rather than being hidden behind the first assert. `ok` still forces exit 1.
	if (result.status !== 0) ok = false;
	return result.stdout || "";
}

function parseSummary(stdout, file, args) {
	const line = stdout.split("\n").find((l) => l.startsWith("SUMMARY_JSON "));
	if (!line) {
		console.error(
			`${file} ${args.join(" ")} did not print a SUMMARY_JSON line for the regression harness`,
		);
		ok = false;
		return undefined;
	}
	return JSON.parse(line.slice("SUMMARY_JSON ".length));
}

function loadGolden(duration) {
	const file = path.join(__dirname, "golden", `baseline-${duration}.json`);
	if (!fs.existsSync(file)) {
		console.error(
			`Missing golden fixture ${file}. It is the frozen lua baseline and must be committed.`,
		);
		process.exit(1);
	}
	return JSON.parse(fs.readFileSync(file, "utf8"));
}

function setDiff(a, b) {
	const bSet = new Set(b);
	return a.filter((x) => !bSet.has(x));
}

// ---------------------------------------------------------------------------------------
// KNOWN BASELINE DIVERGENCES
//
// The golden fixtures are recorded from the lua tree at its PINNED pre-deletion commit
// 232b9f5. Three deliberate changes landed in 7700054 — the very commit that deleted that
// tree — so the baseline recording predates them and can never be re-recorded with them.
// They are rewritten onto the EXPECTED (baseline) side here rather than being excluded from
// the comparison, so the port is still held to an exact value: if the typescript tree ever
// reverts to the old value, the rewritten expectation no longer matches and the suite
// fails. Excluding the fields would have silently permitted both values.
//
// A fourth divergence is NOT deliberate and is reported to Lead rather than fixed here
// (fixing it means touching packages/ee-mission/src, which is out of scope for this task).
const BASELINE_DIVERGENCES = {
	// 1. config.countries: USA(2)/RUSSIA(0) → CJTF_BLUE(80)/CJTF_RED(81).
	//    src/config.ts:180 vs Scripts/ee-dcs/config.lua:67 at 232b9f5. Introduced in 7700054.
	country: { 2: 80, 0: 81 },
	// 2. Stock DCS FARP heliport shape: "FARP" → "FARPS".
	//    DCS MissionEditor/modules/me_exportToMiz.lua:895-944; introduced in 7700054 and
	//    already asserted directly by the authored-FARP fixture in campaign-smoke.lua.
	shape_name: { FARP: "FARPS" },
	// 3. Hot ramp starts. CLAUDE.md guardrail: `type` is what the sim honours, so the old
	//    type="TakeOff" + action="From Parking Area" pair spawned aircraft on the RUNWAY.
	//    Introduced in 7700054 ("hot ramp starts replacing runway starts across 13 sites").
	routePointType: { TakeOff: "TakeOffParkingHot" },
	routePointAction: { "From Parking Area": "From Parking Area Hot" },
};

// 4. FIXED (was: secondary-group RNG draw-order divergence). The port called composition()
//    before spawnOrigin(), consuming the same COUNT of math.random draws in a different ORDER
//    from the Lua baseline's spawn_sec_group, which shifted every GndSec-* spawn origin and
//    group size. src/ground_forces.ts now draws in baseline order, so GndSec-* entries compare
//    EXACTLY like everything else. The 400 m jitter tolerance and the prefix/envelope leniency
//    that stood in for this have been removed rather than left dormant - a tolerance nobody
//    needs is a place a future regression can hide. Verified: the suite passes with zero
//    tolerance, and reverting numericSuffix() still fails these entries.
const POSITION_FIELDS = new Set(["x", "y", "alt"]);

function toleranceFor() {
	return 0;
}

// Rewrites one recorded order from the pinned baseline into what the current port is
// expected to emit, applying only the enumerated deliberate changes above.
function applyDivergences(value, key) {
	if (Array.isArray(value)) return value.map((v) => applyDivergences(v));
	if (value !== null && typeof value === "object") {
		const out = {};
		for (const k of Object.keys(value)) out[k] = applyDivergences(value[k], k);
		return out;
	}
	if (key === "country" && BASELINE_DIVERGENCES.country[value] !== undefined)
		return BASELINE_DIVERGENCES.country[value];
	if (key === "shape_name" && BASELINE_DIVERGENCES.shape_name[value])
		return BASELINE_DIVERGENCES.shape_name[value];
	if (key === "type" && BASELINE_DIVERGENCES.routePointType[value])
		return BASELINE_DIVERGENCES.routePointType[value];
	if (key === "action" && BASELINE_DIVERGENCES.routePointAction[value])
		return BASELINE_DIVERGENCES.routePointAction[value];
	return value;
}

// Deep compare that reports FIELD PATHS, so a failure names the waypoint that moved rather
// than dumping two order blobs at the reader. `tolerance` is metres and applies only to the
// positional fields; every other field, including task ids and route point types, is exact.
function deepDiff(expected, actual, tolerance, path, out) {
	if (out.length > 8) return out;
	const te = expected === null ? "null" : typeof expected;
	const ta = actual === null ? "null" : typeof actual;
	if (te !== ta) {
		out.push(
			`${path}: ${JSON.stringify(expected)} vs ${JSON.stringify(actual)}`,
		);
		return out;
	}
	if (te === "number") {
		const leaf = path.slice(path.lastIndexOf(".") + 1).replace(/\[\d+\]$/, "");
		const tol = POSITION_FIELDS.has(leaf) ? tolerance : 0;
		if (Math.abs(expected - actual) > tol)
			out.push(`${path}: ${expected} vs ${actual}`);
		return out;
	}
	if (te !== "object") {
		if (expected !== actual)
			out.push(
				`${path}: ${JSON.stringify(expected)} vs ${JSON.stringify(actual)}`,
			);
		return out;
	}
	if (Array.isArray(expected) !== Array.isArray(actual)) {
		out.push(`${path}: array/object shape differs`);
		return out;
	}
	if (Array.isArray(expected)) {
		if (expected.length !== actual.length)
			out.push(`${path}: length ${expected.length} vs ${actual.length}`);
		for (let i = 0; i < Math.min(expected.length, actual.length); i += 1)
			deepDiff(expected[i], actual[i], tolerance, `${path}[${i}]`, out);
		return out;
	}
	for (const k of new Set([...Object.keys(expected), ...Object.keys(actual)]))
		deepDiff(expected[k], actual[k], tolerance, `${path}.${k}`, out);
	return out;
}

// Ordered, duplicate-preserving comparison of every order issued at the engine boundary.
// This is the check that names/ticks could not make: it sees destination waypoints, task
// parameters, unit composition, AND call multiplicity (repeats are separate list entries).
function compareOrders(expected, actual, expectedLabel, actualLabel, failures) {
	if (!Array.isArray(expected) || !Array.isArray(actual)) {
		failures.push(
			`order log missing (${expectedLabel}=${typeof expected}, ${actualLabel}=${typeof actual}).` +
				" Re-record the golden fixtures: node test/run-tests.cjs --record-golden <lua-tree-root>",
		);
		return;
	}
	if (expected.length !== actual.length)
		failures.push(
			`order COUNT differs: ${expectedLabel}=${expected.length} ${actualLabel}=${actual.length}` +
				" (a dropped, duplicated or extra addGroup/addStatic/setTask/pushTask call)",
		);
	let reported = 0;
	for (let i = 0; i < Math.min(expected.length, actual.length); i += 1) {
		const want = applyDivergences(expected[i]);
		const have = actual[i];
		// Every order, GndSec-* included, is compared EXACTLY — see note 4 above.
		const diff = deepDiff(want, have, 0, "", []);
		if (diff.length === 0) continue;
		if (reported < 6)
			failures.push(
				`order #${i} ${actual[i].call ?? "?"} ${actual[i].group ?? "?"} differs` +
					` (${expectedLabel} vs ${actualLabel}):\n      ` +
					diff.join("\n      "),
			);
		reported += 1;
	}
	if (reported > 6)
		failures.push(`...and ${reported - 6} further order divergences`);
}

// Exact per-key comparison of a count map (task creations by type, spawn calls by name,
// generator liveness). A key present on one side only is reported as a 0.
function compareCounts(
	label,
	expected,
	actual,
	expectedLabel,
	actualLabel,
	failures,
) {
	const keys = [
		...new Set([...Object.keys(expected ?? {}), ...Object.keys(actual ?? {})]),
	].sort();
	const bad = keys
		.filter((k) => (expected?.[k] ?? 0) !== (actual?.[k] ?? 0))
		.map(
			(k) =>
				`${k}: ${expectedLabel}=${expected?.[k] ?? 0} ${actualLabel}=${actual?.[k] ?? 0}`,
		);
	if (bad.length)
		failures.push(`${label} differ:\n      ` + bad.join("\n      "));
}

// Compares two world-state snapshots. `expectedLabel`/`actualLabel` name the two sides so the
// same routine serves both legs (golden-vs-typescript and lua-vs-typescript).
//
// Log line count is NOT compared: the trees emit different amounts of env.info() verbosity by
// design, so it is deliberately excluded as a known-noisy field.
function compareSummaries(
	duration,
	expected,
	actual,
	expectedLabel,
	actualLabel,
) {
	const failures = [];

	// Timer tick count: the staggered-timer schedule (game_loop.start()) must be identical.
	// A differing tick count means timers were scheduled or cancelled differently.
	if (expected.ticks !== actual.ticks) {
		failures.push(
			`timer tick count differs: ${expectedLabel}=${expected.ticks} ${actualLabel}=${actual.ticks}`,
		);
	}

	const groupsOnlyExpected = setDiff(expected.group_names, actual.group_names);
	const groupsOnlyActual = setDiff(actual.group_names, expected.group_names);
	if (groupsOnlyExpected.length || groupsOnlyActual.length) {
		failures.push(
			`spawned group names differ (${expectedLabel}=${expected.groups} groups, ${actualLabel}=${actual.groups} groups):\n` +
				`    only in ${expectedLabel}: ${JSON.stringify(groupsOnlyExpected)}\n` +
				`    only in ${actualLabel}: ${JSON.stringify(groupsOnlyActual)}`,
		);
	}

	const staticsOnlyExpected = setDiff(
		expected.static_names,
		actual.static_names,
	);
	const staticsOnlyActual = setDiff(actual.static_names, expected.static_names);
	if (staticsOnlyExpected.length || staticsOnlyActual.length) {
		failures.push(
			`spawned static names differ (${expectedLabel}=${expected.statics} statics, ${actualLabel}=${actual.statics} statics):\n` +
				`    only in ${expectedLabel}: ${JSON.stringify(staticsOnlyExpected)}\n` +
				`    only in ${actualLabel}: ${JSON.stringify(staticsOnlyActual)}`,
		);
	}

	// Orders, multiplicity and per-type task creation — the checks the name/tick pair is
	// blind to. Everything above can be identical while the campaign sends every group to
	// the wrong place or runs a generator that produces nothing at all.
	compareOrders(
		expected.orders,
		actual.orders,
		expectedLabel,
		actualLabel,
		failures,
	);
	compareCounts(
		"spawn call multiplicity",
		expected.spawn_call_counts,
		actual.spawn_call_counts,
		expectedLabel,
		actualLabel,
		failures,
	);
	compareCounts(
		"board task creations by type",
		expected.task_creations,
		actual.task_creations,
		expectedLabel,
		actualLabel,
		failures,
	);
	compareCounts(
		"generator liveness",
		expected.generator_liveness,
		actual.generator_liveness,
		expectedLabel,
		actualLabel,
		failures,
	);

	if (failures.length) {
		console.error(
			`\nREGRESSION at duration=${duration}s (${expectedLabel} vs ${actualLabel}):`,
		);
		for (const failure of failures) console.error(`  - ${failure}`);
		return false;
	}

	console.log(
		`\nOK at duration=${duration}s: ticks=${expected.ticks}, groups=${expected.groups},` +
			` statics=${expected.statics}, orders=${actual.orders.length},` +
			` task types=${Object.keys(actual.task_creations ?? {}).length}` +
			` match between ${expectedLabel} and ${actualLabel}`,
	);
	return true;
}

// Golden recording. The fixtures are the LUA BASELINE's answers, taken from its pinned
// pre-deletion commit (232b9f5) checked out into a scratch directory — the tree is
// deliberately NOT restored into the repository working copy.
//
//   git archive 232b9f5 Scripts/ee-dcs | tar -x -C <scratch>
//   node packages/ee-mission/test/run-tests.cjs --record-golden <scratch>
//
// Re-record only when a change to the BASELINE expectation is intended, and review the diff.
if (process.argv[2] === "--record-golden") {
	const treeRoot = process.argv[3];
	if (
		!treeRoot ||
		!fs.existsSync(path.join(treeRoot, "Scripts", "ee-dcs", "main.lua"))
	) {
		console.error(
			"--record-golden needs a directory containing Scripts/ee-dcs/main.lua from commit 232b9f5",
		);
		process.exit(1);
	}
	for (const duration of ["310", "2100"]) {
		const args = ["lua", duration, treeRoot];
		const summary = parseSummary(
			run("campaign-smoke.lua", args),
			"campaign-smoke.lua",
			args,
		);
		const file = path.join(__dirname, "golden", `baseline-${duration}.json`);
		fs.writeFileSync(file, `${JSON.stringify(summary, null, "\t")}\n`);
		console.log(`recorded ${file} (${summary.orders.length} orders)`);
	}
	process.exit(0);
}

run("core-parity.lua", []);

if (!luaTreePresent) {
	console.log(
		`\nSKIP lua legs: ${path.relative(root, luaTreeEntry)} is not present.` +
			"\n     The lua baseline has been deleted; the typescript run is asserted against the" +
			"\n     committed golden fixtures in test/golden/ instead.",
	);
}

for (const duration of ["310", "2100"]) {
	const golden = loadGolden(duration);
	const tsArgs = ["typescript", duration];
	const tsSummary = parseSummary(
		run("campaign-smoke.lua", tsArgs),
		"campaign-smoke.lua",
		tsArgs,
	);

	// Leg 1 — the durable net.
	if (
		tsSummary &&
		!compareSummaries(duration, golden, tsSummary, "golden", "typescript")
	)
		ok = false;

	// Leg 2 — live differential, only while the lua tree exists.
	if (luaTreePresent) {
		const luaArgs = ["lua", duration];
		const luaSummary = parseSummary(
			run("campaign-smoke.lua", luaArgs),
			"campaign-smoke.lua",
			luaArgs,
		);
		if (
			luaSummary &&
			!compareSummaries(duration, golden, luaSummary, "golden", "lua")
		)
			ok = false;
		if (
			luaSummary &&
			tsSummary &&
			!compareSummaries(duration, luaSummary, tsSummary, "lua", "typescript")
		)
			ok = false;
	}
}

if (!ok) process.exit(1);
