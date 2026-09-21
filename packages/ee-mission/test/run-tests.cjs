// Offline regression harness for the ee-dcs campaign port.
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
const fs = require("node:fs");
const { spawnSync } = require("node:child_process");
const path = require("node:path");

const root = path.resolve(__dirname, "../../..");
const lua = process.env.LUA_BIN || "lua";
const luaTreeEntry = path.join(root, "Scripts", "ee-dcs", "main.lua");
const luaTreePresent = fs.existsSync(luaTreeEntry);

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
	if (result.status !== 0) process.exit(result.status || 1);
	return result.stdout || "";
}

function parseSummary(stdout, file, args) {
	const line = stdout.split("\n").find((l) => l.startsWith("SUMMARY_JSON "));
	if (!line) {
		console.error(
			`${file} ${args.join(" ")} did not print a SUMMARY_JSON line for the regression harness`,
		);
		process.exit(1);
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

	if (failures.length) {
		console.error(
			`\nREGRESSION at duration=${duration}s (${expectedLabel} vs ${actualLabel}):`,
		);
		for (const failure of failures) console.error(`  - ${failure}`);
		return false;
	}

	console.log(
		`\nOK at duration=${duration}s: ticks=${expected.ticks}, groups=${expected.groups}, statics=${expected.statics} match between ${expectedLabel} and ${actualLabel}`,
	);
	return true;
}

let ok = true;

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
	if (!compareSummaries(duration, golden, tsSummary, "golden", "typescript"))
		ok = false;

	// Leg 2 — live differential, only while the lua tree exists.
	if (luaTreePresent) {
		const luaArgs = ["lua", duration];
		const luaSummary = parseSummary(
			run("campaign-smoke.lua", luaArgs),
			"campaign-smoke.lua",
			luaArgs,
		);
		if (!compareSummaries(duration, golden, luaSummary, "golden", "lua"))
			ok = false;
		if (!compareSummaries(duration, luaSummary, tsSummary, "lua", "typescript"))
			ok = false;
	}
}

if (!ok) process.exit(1);
