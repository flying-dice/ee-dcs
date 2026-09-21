# Decision 0001 — Preserve campaign semantics during TSTL migration

Date: 2026-09-20

The existing Lua campaign is the behavioral baseline for this source-language migration. Preserve constants, public names, EECH citations, generation cancellation and initialization order. Keep strict TypeScript checks and explicit DCS ambient contracts. Output the bundle to root `dist` to preserve injection paths.

Retain Lua sources for comparison and live-validation rollback. Configuration must be validated before loading modules that capture configuration at module scope; static import hoisting must not change that sequence.
