---
name: live-evidence-beats-inspection
description: On this port, probe the running sim before designing against assumed DCS behaviour — code inspection repeatedly missed measurable defects
metadata:
  type: feedback
---

Before designing anything that depends on DCS API behaviour, probe a running mission and
measure it. Do not design from comments, from the Mission Editor's documented shapes, or from
what the code appears to assume.

**Why:** in one probe session on 2026-09-22 this found three things no amount of code reading
had caught: FARP stands are `Term_Index` **0-based** while the port emitted "1".."4" (so one
stand was invalid and pad 0 unusable); `getParking(true)` does **not** reflect occupancy; and
a departed aircraft **keeps** its stand reserved. It also showed `S_EVENT_LAND` carries a real
landing-site identity, which let an entire positional proxy be deleted rather than worked
around, and revealed that aircraft losses arrive as `S_EVENT_CRASH` not `S_EVENT_DEAD` —
meaning nothing ever regenerated (backlog card 28).

**How to apply:** when a package's design rests on an unverified DCS behaviour, spend a probe
session first and write the measurements into a dated doc that briefs cite as ground truth.
Capture the raw event ring to `dcs-bugs/` — it doubles as real test fixtures and as a
before/after control. Always write down the **falsifier** for any "this fix probably caused
that improvement" hypothesis. Also: a long taxi (~7.5 min at Sukhumi) means elapsed time is
never evidence of failure. See [[dcs-live-bridge]], [[eech-prime-directive]].
