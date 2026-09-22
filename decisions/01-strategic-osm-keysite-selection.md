---
status: Superseded
date: 2026-09-21
---
# Decision 01 — Select strategic OSM keysites conservatively

Later Decisions 02, 04 and 05 supersede its industrial, geographic-selection and power rules.

## Context

The campaign normally uses two factories and roughly one site of each other strategic type per side, but the Caucasus export offered hundreds of candidates. Broad tags such as `man_made=works` and `industrial=oil` admitted service buildings, oil tanks and pump stations. A dense mapping area could dominate the icon layer while other regions had few alternatives.

## Decision

The exporter and browser share one named-site policy. Manufacturing requires an explicit factory tag or a works tag with a stated product. Refineries require explicit refinery evidence; oil storage/terminals become fuel sites. Large power plants continue to require at least 100 MW documented electrical output. Ports must be maritime/ferry facilities; weather radar and generic civilian depots do not become campaign military sites. After ranking mapped facilities, keep at most two factories, power plants, ports and fuel sites per resolution-3 H3 cell. Do not fabricate OSM suggestions to fill missing classes.

## Consequences

The Caucasus candidate set is much smaller and more geographically distributed. Some real facilities with incomplete OSM tagging will be omitted, and radar has no automatic candidate in the current export. The policy test cases and rebuilt asset should be reviewed whenever another theatre or tagging convention is added.
