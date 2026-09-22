# Campaign source migration

1. Complete: Port all 34 campaign modules to strict TypeScript-to-Lua, retaining exported APIs and original EECH header citations.
2. Complete: Build the root bundle and verify boot, reinjection, scheduling and persistence with differential and simulated campaign tests.
3. Complete (with waiver): Lua baseline removed 2026-09-21. DCS Studio was unreachable, so the
   live-validation half of this gate was **waived by the Lead** and replaced with an offline
   regression net: golden fixtures recorded from the baseline pre-deletion, asserted on every
   test run (`packages/ee-mission/test/golden/`). See sprint 02 for the waiver and residual risk.
4. Outstanding: DCS Studio static analysis + live in-mission validation. Still required before an
   MP playout — and now more so: sprint 02 found the SEAD and BAI generators were silently dead in
   the TypeScript port, and reactivating them is a real behavioural change no offline test can
   fully validate.
   Issue #3 is now reproduced live: FARP helicopter groups disappear within one
   second; the same AH-64D specification works initially and after aircraft
   recycling at an authored FARP. Generator now bakes stock FARPs before load;
   checks pass and observed RED/BLUE campaign sections have taken off. Ground
   clearance also has a tested automatic evacuation loop. Retain
   [ED evidence and workarounds](../../dcs-bugs/runtime-farp-spawning/README.md).

## Web scenario authoring

1. Complete: Bake OSM keysite and administrative-boundary data into each theatre asset.
2. Complete: Replace forward-axis authoring with explicit BLU/RED and Rear/Close territory assignments.
3. Complete: Use territory containment for airbase ownership, main-airbase validation and role-constrained keysite generation.
