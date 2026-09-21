---
status: Accepted
date: 2026-09-21
---
# Decision 07 — Export candidates only inside the active map area

The theatre's full terrain polygon reaches far beyond the playable area shown by the UI. After classifying source features and choosing their spawn points, retain only points inside the UI's airfield envelope with its 100 km buffer, clamped to the theatre bounds. This is a final spatial crop, not a density cap: retain every eligible industrial polygon whose centre lies inside the area, and do not deduplicate by H3 cell or region. If a theatre has no airfields, use the terrain bounds.
