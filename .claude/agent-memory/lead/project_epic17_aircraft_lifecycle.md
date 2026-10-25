---
name: epic17-aircraft-lifecycle
description: Epic #17 (aircraft lifecycle) is the active workstream from 2026-09-22 — sequenced P0..P5, live DCS gate P5 may be unrunnable
metadata:
  type: project
---

Epic #17 "allocated sortie -> live aircraft -> takeoff -> return/loss" is the active
workstream from 2026-09-22 (sprint 04). It owns physical aircraft lifecycle and base
departure/recovery, NOT combat task selection. Issues #2 and #3 are closed and are
regression baselines only; #11 (live hot-ramp validation) is still open under it.

The user supplied a detailed, pre-agreed execution plan with ordered packages
P0 (test harness + caller map) -> P1 (submission outcomes) -> P2 (parking leases)
-> P3 (per-aircraft recovery) -> P4 (integrate + regression) -> P5 (live witness).

**Why:** the port conflates queue acceptance with physical spawn success, settles a
whole group on the first member's landing, and has no cross-group FARP parking
reservation — so reserve/slot accounting silently corrupts.

**Status 2026-09-23:** P0-P4 are complete and green offline (sprint 04, ADRs 0009/0010).
**P5 is pending and #17 is still open** — it needs a *freshly generated* `.miz`; Lua
re-injection into an existing mission is explicitly not equivalent. Runbook:
`docs/bots/P5-LIVE-WITNESS-RUNBOOK.md`.

**How to apply:** follow the package order; do not let a bot skip ahead. P2 and P3 both extend
`aircraft_lifecycle.ts`, so they cannot run in parallel. When resuming, read the sprint file
and the caller map's P4 integration matrix first. Do not close #17 on offline evidence, and do
not fix backlog card 28 (losses never regenerate) without EECH grounding.
See [[eech-prime-directive]], [[live-evidence-beats-inspection]], [[dcs-live-bridge]].
