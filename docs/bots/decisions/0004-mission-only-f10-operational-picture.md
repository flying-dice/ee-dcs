# ADR 0004: Mission-only F10 operational picture

## Context

The campaign stores bases, installations, primary/secondary/artillery formations, active and queued missions, logistics, production, regeneration, objectives, threat maps and fog-of-war. The existing F10 overlay exposes only base/keysite labels, individual asset pins, primary ground groups, some unlabelled sortie lines and one closest-pair midpoint labelled as the frontline.

The generated `.miz` must remain self-contained. Client modules, WebView UI, `Export.lua`, external dashboards and per-player installations are outside the delivery model.

## Decision

Use DCS mission-native F10 map markup and `missionCommands` as the campaign interface.

- Render a compact coalition-scoped overview by default.
- Show complete friendly operational state and filter enemy state through the existing fog-of-war threshold.
- Represent the front from the same base topology used by campaign logic rather than a single midpoint.
- Reconcile stable marker IDs against current campaign state so captures, task completion, movement and intelligence changes update or remove marks safely.
- Show queued and active missions with type, priority/status, origin and target.
- Include primary, artillery and secondary ground echelons while keeping individual destructible assets out of the default view.
- Put detailed situation, tasking, logistics, production, regeneration and intelligence reports in the coalition F10 Campaign menu.
- Keep display state separate from campaign mechanics; map controls may change presentation only.

## Consequences

The mission remains a portable `.miz` with no client installation. Coalition players receive a substantially richer operational picture without exposing omniscient enemy details. DCS map markup has limited interaction and layout, so dense tables remain text reports and layer controls are coalition-wide. Live DCS validation remains necessary because offline mocks cannot prove markup rendering behavior.
