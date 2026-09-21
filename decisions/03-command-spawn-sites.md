---
status: Accepted
date: 2026-09-21
---
# Decision 03 — Broaden command spawn-site candidates

## Context

The prior OSM filter only included a handful of `military=*` values and required a name for command sites. It omitted many mapped military land areas. The user wants those sites available without losing the newly found `military=base` candidates, and also wants civic centres and substantial government buildings as command options.

## Decision

Keep every existing named `military=base` command candidate. Add military-area, barracks and naval-base footprints as command candidates; exclude military components, airfields, danger areas and abandoned sites. Add town halls, named civic centres and government-office/building footprints above a minimum area as civilian command candidates. Decision 04 supersedes the original generic-site regional quotas. Each selected feature remains one point with one command kind.

## Consequences

The broader military and civic command pool gives the generator more spawn locations across the theatre, while explicit bases are not displaced by generic areas. A military or government tag denotes a plausible spawn anchor, not a claim that the campaign's command facility exists there.
