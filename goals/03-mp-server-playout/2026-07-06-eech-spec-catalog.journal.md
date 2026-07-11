# Journal: MP-server playout — 2026-07-06 (eech-spec-catalog)

**Goal:** goals/03-mp-server-playout/GOAL.md
**Session focus:** User directive — step through the EECH C codebase and catalog EVERY campaign
feature into a complete spec set under specs/. This becomes the checkable ground truth for
"direct port" fidelity (replacing journal lore) and will surface unported features.

## Log
### 11:00 — EECH source tree scouted, partition decided
Real layout (corrects the journals' shorthand): campaign code lives in
aphavoc/source/ai/{highlevl,taskgen,faction,frontl,ai_misc}/ and
aphavoc/source/entity/special/{session,force,keysite,sector,task,group,division,regen,pilot,
update,waypoint,guide,landing}/ plus entity/system/en_types/, gameflow/, comms/.
Notable finds: ai/taskgen/ (assign.c/engage.c/croute.c — the task-assignment engine under
highlevl), ai/faction/ (parser.c/popread.c/routegen.c — warzone data + ROAD NETWORK
generation), entity/special/pilot/ + comms/ (EECH's own MP pilot/join model — direct goal-03
relevance), ui_menu/ingame/campaign/campaign.c.

Partition → 10 spec files, one Opus agent each, common template (Overview / Data model /
numbered features with constants+formulas+file:line / Interactions / Port mapping / Open
questions). Feature IDs like TASKGEN-F3 for backlog cross-referencing:
01-session-lifecycle, 02-force-win-criteria, 03-keysites-supply, 04-task-generation,
05-reaction, 06-sectors-fow-imaps-frontline, 07-task-engine-routing,
08-groups-divisions-regen, 09-warzone-data-roads, 10-pilots-multiplayer.
Coordinator writes specs/00-INDEX.md after review.

### 11:20 — USER DIRECTIVE: no fan-out — one Fable agent
Launched the 10-agent fan-out; user immediately corrected: "do not fan out, just dispatch one
single fable agent to read and understand the codebase and transpose it into specs." All 10
Opus agents stopped before any spec file was written (specs/ verified empty). Re-dispatched as
a SINGLE Fable agent carrying the full consolidated brief: same 10-file partition + 00-INDEX,
same template/citation rules/port-mapping context, instructed to write each spec file
incrementally as its area completes (progress banked against context limits).

### 12:00 — Spec catalog COMPLETE (single Fable agent)
All 11 files written to specs/: 00-INDEX + 10 subsystem specs, 214 features total
(SESSION-F20, FORCE-F37, KEYSITE-F19, TASKGEN-F17, REACT-F14, SECTOR-F19, TASK-F26,
GROUP-F16, WARZONE-F21, PILOT-F25), every constant cited eech file:line, port status
annotated per feature. NOT deep-reviewed by coordinator (user usage constraint) — a
verification pass is a follow-up.

Top gaps found (full list in specs/00-INDEX.md): (1) fc_updt.c criteria evaluator is DEAD
CODE — shipped EECH ends only via 5 objective keysites / no usable airbases / no flyable
combat helis; the port's 4h timeout is an invention; (2) no task board — EECH assigns
EXISTING idle groups (suitability matrix, keysite budgets, 10-min unassigned expiry);
(3) producer→consumer supply economy (factories→crates→rearm-time) absent; (4) capture:
EECH efficiency<0.3 + probabilistic vs port deterministic <0.80, capture side-effects
missing; (5) FOW radii invented — real model is per-unit recon_radius×2 linear falloff;
(6) persistence; (7) sector grid/road network + frontline computed once at load; (8) reserve
recycle has ZERO callers in shipped EECH (design intent only); rg_dbase empty, regen cadence
data-driven; (9) pilot/player career + human mission assignment; (10) landing-slot
arbitration throttling sortie tempo. Also: keysite efficiency formula mismatch; documented
source quirks not to "fix" (assign.c:497 lowest-positive pick, regen overwrite-oldest,
×1000 flying-hours bug).

## Next steps
- Coordinator/adversarial verification pass over specs/ (spot-check citations vs C source)
- Reconcile the port against the spec: several goal-02 "faithful" claims now need review
  (win criteria, capture thresholds, FOW radii, recycle-on-RTB) — fold into goal-03 backlog
  as a new fidelity cluster keyed by feature IDs
- Update GOAL.md/backlog to cite spec feature IDs (e.g. FORCE-F*, TASK-F*) as acceptance refs

## Open questions
- Which spec-revealed divergences are bugs to fix vs deliberate port improvements to keep
  (e.g. 4h timeout, deterministic capture)? User call, per-feature.

## Follow-ups & improvements
- Spec verification pass was skipped due to usage limits — do before trusting constants
- Consider regenerating README's "faithful port" wording once divergences are triaged
