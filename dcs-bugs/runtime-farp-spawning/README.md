# Dynamic helicopter activation at runtime-created stock FARPs

Status: reproduced in a controlled comparison, 22 September 2026. Prepared for
Eagle Dynamics review; not submitted. Mission-authored FARP spawning and recycling
worked; the same aircraft specification failed at a fresh runtime-created FARP.
The exact engine root cause is not established.

## Problem

In campaign tests, `coalition.addGroup` returns a helicopter group with two units,
but those units disappear within one simulation second when departing from a
runtime-created stock FARP. Immediate existence, life and group-size checks can
misleadingly appear successful. `Unit:isActive()`, subsequent unit lookups and
birth/takeoff events distinguish these placeholders from active aircraft.

Expected: a valid hot-parking helicopter group on an empty four-position FARP
activates and takes off, or a documented restriction/error explains rejection.

Observed controls: an exact Mission Editor AH-64D group submitted dynamically at
an empty mission-authored FARP activates and takes off. Destroying that group and
respawning on the same FARP also works according to the user's live observation.
The fresh runtime-created FARP failed with the same aircraft specification:
returned units were inactive, then absent by +1 second without birth events.

## Environment

- DCS version **2.9.29.27468**, x86_64, English; installed updater metadata reports
  branch `openbeta`, build timestamp `20260902-093323`.
- Map: Caucasus.
- Aircraft: two AI AH-64D for the clean authored-FARP control. Earlier campaign
  failures also involved two RED Mi-24V and two BLUE AH-64D.
- Stock static heliport: `type="FARP"`, `shape_name="FARPS"`,
  `category="Heliports"` (four positions).
- Authored empty control: user-supplied `farp.miz`; country USA (2), BLUE,
  `Static FARP-1-1`, airbase ID 2.
- Scripts executed in mission scripting context through DCS Studio bridge 0.4.0.
  DCS Studio is a delivery mechanism; a minimal reproduction should use mission
  triggers with the supplied Lua so the bridge is not a prerequisite.

## Evidence matrix

| Test | Result | Interpretation / limits |
| --- | --- | --- |
| Original campaign hot runtime-FARP launch, both types | Returned units disappear by +1 s | Reproduces symptom; campaign is a complex fixture |
| Cold-only and simpler-route variants | Same disappearance | Neither change alone fixes the symptom |
| Airborne and ordinary-airfield controls | Active aircraft; airborne or taxiing | Aircraft/API can work outside this departure path |
| Dynamic clone at occupied authored FARP | Present but inactive through +120 s | Parking was later found reserved; exclude as proof of an authored-FARP failure |
| Fresh runtime FARP, runtime pad IDs/coordinates | Inactive initially, absent by +1/+5/+30 s | Changed parking representation as well; not the final exact-spec comparison |
| Empty authored FARP, exact reference hot AH-64D pair | Both active at +1 s, both airborne at +120 s; birth and takeoff events | Valid positive control; user saw both take off and return |
| Destroy successful pair, reuse same authored FARP | User confirms fresh pair takes off | Supports repeated use without mission reload; detailed trace being retained |
| Fresh runtime FARP, same successful specification in same clean mission | Four free pads; returned units inactive, then absent at +1/+5/+30 s; no birth/takeoff | Reproduced difference; location and heliport/warehouse initialization remain possible causes |

Earlier ground-hot placement at runtime pad coordinates produced one crashed
Mi-24V and one flying Mi-24V. That is not a successful two-aircraft workaround.
AH-64 damage-model warnings also occurred in a working reference run and are not
established as the cause.

## Reproduction requirements

1. Load the minimal Caucasus mission containing one empty stock four-position
   FARP. Keep it running throughout the authored/recycle/runtime comparison.
2. Record the authored FARP identity, coalition, location and all/free parking.
3. Submit the exact reference two-AH-64D hot-parking specification with unique
   names and no colliding group/unit IDs. Preserve payload, speeds, start mode,
   parking representation and route between comparisons.
4. Record API result; per-unit presence, existence, **activity**, life, position
   and airborne state at 0, 1, 5, 30 and 120 simulation seconds; record birth,
   takeoff, crash and death events from before submission.
5. Destroy only the named test group. Confirm disappearance and free parking,
   then spawn a fresh uniquely named pair at the same authored FARP. Do not
   destroy/recreate the FARP or reload the mission.
6. Create one isolated runtime stock FARP. Confirm four free terminals. Repeat
   the proven specification, changing only names, required coordinates and FARP
   links. Record creation-to-submission delay and exact static definition.
7. If the runtime case succeeds, recycle and repeat there. If it fails, retain
   the exact failing specification and positive control together.

See [measured evidence and exact trigger schedule](evidence.md),
[authored control](authored-control.lua), [aircraft recycling](recycle-authored.lua)
and [runtime FARP reproduction](runtime-farp.lua). Load the supplied [farp.miz](farp.miz)
on Caucasus. In Mission Editor, add ONCE / TIME MORE triggers using DO SCRIPT FILE
to run the authored control and later the runtime reproduction; allow at least
120 simulation seconds between them. Alternatively execute each file in the
mission scripting context of the running mission. Retain the test names so the
observers can correlate the aircraft. The aircraft-only recycle test should
destroy the named control group and wait for parking release before rerunning it.

The supplied scripts package the tested specifications; their trigger-based
delivery has not itself been replayed live. The measured session used the Studio
bridge. A runtime-FARP recycle was not attempted because its first pair failed.

## Workaround and validation

See [detailed workarounds](workarounds.md). The implemented workaround includes stock FARPs
in the generated mission before it loads, then reuse those objects for dynamic
campaign aircraft. Clean authored-FARP flight and reuse are demonstrated; the
[generated-campaign check](generated-campaign-validation.md) subsequently passed
for observed RED Mi-24V and BLUE AH-64D sections: activation, survival, takeoff
events and airborne state at +120 seconds. One separate RED crash remains recorded.

## Questions for Eagle Dynamics

The controlled difference raises these questions:

1. Are runtime-created stock FARPs supported for AI hot-parking `addGroup`
   departures, and what initialization steps or delay are required?
2. Is the Mission Editor's parking/link encoding valid for such FARPs, or must
   dynamic callers use a different documented representation?
3. Why can `addGroup` return handles with life and size before units disappear
   without birth events? Is there an available rejection reason?
4. Are warehouse/parking initialization differences between authored and runtime
   FARPs relevant to AI activation and subsequent reuse?

The [dynamic player spawn slots discussion](https://forum.dcs.world/topic/353321-how-to-dynamically-create-a-new-farp-with-dynamic-spawn-slots/)
is background, not proof of the same defect: this report concerns **AI groups**.

## Supporting material

- [Project diagnostic record](../../docs/bots/helicopter-spawn-diagnostics.md).
- [Minimal empty authored FARP mission](farp.miz), SHA-256:
  `2B7E67E392AB5302BAD36ADE5AF0AC1AB19426907A3CDF3C0F609CD780529EE4`.
- [Measured comparison and bounded log excerpts](evidence.md).
- Exact original authored-control archive SHA-256:
  `E0ED0CF30B71F337E00C5403968E3888D8E8D360E0DD11213DB3E3C56C58CCFC`.
- Local investigation sources: `scratchpad/issue3-me-reference/`; these are
  working evidence, not a substitute for the shareable files in this folder.
- Full logs remain local. Include only relevant trace excerpts in an ED package.
