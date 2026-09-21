---
status: Accepted
date: 2026-09-21
---
# Decision 05 — Major substations are power spawn targets

## Context

The power policy only recognised named generating plants with documented output of at least 100 MW. Zugdidi 220 kV is a mapped transmission substation and a suitable campaign power target, but was absent because the OSM filter and classifier ignored `power=substation`.

## Decision

Export `power=substation` areas and classify them as power candidates when their documented `voltage=*` contains at least one value of 220,000 V or higher. Parse semicolon-separated voltage levels as OSM specifies. Exclude minor-distribution, traction, industrial, transport and transition substation roles even if a voltage tag looks high. Do not require a name; unnamed qualifying areas receive a descriptive fallback name. Keep the existing large-generating-plant rule, and apply no regional cap or proximity deduplication.

## Consequences

Grid-scale transformer and switching sites such as Zugdidi 220 kV can be selected as power spawn locations without admitting ordinary 110 kV and lower distribution sites or individual `power=transformer` components. A high-voltage tag is evidence of grid scale, not proof of generating capacity; the map's power kind now covers both generation and transmission targets.
