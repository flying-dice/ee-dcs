/** @noSelfInFile */
// lua_interop.ts — TSTL/Lua interop correctness helpers.
//
// NOT campaign logic. Nothing here models EECH behaviour, so there is deliberately no EECH
// `file:line` citation on any of it — reviewers applying the CLAUDE.md PRIME DIRECTIVE should not
// expect one. This module exists because typescript-to-lua's handling of Lua multi-return values
// has a trap that silently produced wrong campaign behaviour twice in this port.
//
// THE TRAP
// `string.match()` is typed as a LuaMultiReturn. Used directly inside an expression, TSTL wraps it
// in a TABLE CONSTRUCTOR:
//
//     const found = string.match(n, p);        ->   local found = {string.match(n, p)}
//
// A table is never nil and never a number, so:
//   * `found !== undefined` is ALWAYS TRUE  and `found === undefined` always false
//   * `tonumber(found)` is ALWAYS nil
//
// Damage this actually caused in the shipping bundle before it was found:
//   * `cas_bai_sead` classified every ground group as PRIMARY, so `aaTargets()` returned zero
//     targets on every pass — the SEAD and BAI generators produced nothing, ever.
//   * `supply.classify_role` always returned the first role, so RTB recycling credited the wrong
//     reserve pool.
//   * `ground_forces.numericSuffix` always returned 0, collapsing the five-slot lateral dispersion
//     of artillery and secondary groups onto a single deployment point.
//
// THE FIX
// Destructuring forces the single-value form — `local found = string.match(n, p)` — which is what
// the Lua baseline's `n:match(...)` did. Both helpers below are deliberately thin: their whole
// purpose is to be the ONE place this destructuring is written, so the trap cannot be reintroduced
// by copying a call site.
//
// If you add another Lua multi-return API to this port (`string.find`, `string.gsub`, `pcall`,
// `next`, ...), destructure it at the call site or add a wrapper here. Never assign one to a
// single variable and test it.

/** True when `pattern` matches `text`. Mirrors the Lua baseline's `text:match(pattern)` truth test. */
export function matches(text: string, pattern: string): boolean {
	const [found] = string.match(text, pattern);
	return found !== undefined;
}

/**
 * Trailing integer of a group name, or 0 when it has none.
 * Mirrors the Lua baseline's `tonumber(name:match("(%d+)$")) or 0`
 * (see `git show HEAD~1:Scripts/ee-dcs/ground_forces.lua`, the advance/retreat slot logic).
 */
export function numericSuffix(name: string): number {
	const [match] = string.match(name, "(%d+)$");
	return match !== undefined ? (tonumber(match) ?? 0) : 0;
}
