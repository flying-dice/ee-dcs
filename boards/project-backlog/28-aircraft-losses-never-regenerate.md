# 28 — Shot-down aircraft never enqueue a regeneration replacement

**Severity: high (campaign economy).** Found 2026-09-22 during epic #17 P3, confirmed
independently by Lead against a 219-event live capture.

## The defect

`regen.make_dead_handler` subscribes to **`S_EVENT_DEAD` (id=8)** only. In DCS, an aircraft
loss arrives as **`S_EVENT_CRASH` (id=5)**.

Measured over ~3 hours of live campaign, 305 events
(`dcs-bugs/aircraft-lifecycle/probe-events-pre-p2.txt`, mission clock t=10594):

| event | count | aircraft among them |
| --- | --- | --- |
| CRASH (5) | 40 | **all 40** |
| DEAD (8) | 70 | **zero** — ground columns, artillery, air-defence, statics only |

Re-verified by Lead on the larger sample after an initial 219-event check gave the same
split (32/32 and 0/39). The result is stable, not a small-sample artefact.

So **no shot-down aircraft has ever enqueued a regeneration replacement.** Aircraft attrition
is permanent and one-directional: the reserve drains and never refills from losses. Every
campaign run to date has been playing with a broken aircraft economy, which plausibly distorts
any long-soak observation of force balance made so far.

## Why it was invisible

`make_dead_handler` is correct *for ground units*, which is where it was exercised, and the
offline suite has no fixture asserting that an aircraft loss produces a regen entry. The bug
only shows against real DCS event traffic.

## What to do

Not a one-line fix to `if id == DEAD` — establish first, from the EECH C source, what the port
should do on an aircraft loss:

- `force.c:249-271` `remove_from_force_info` — one entity, `force_info_current_hardware[index]--`,
  loss stat at `:258`.
- `force.c:278-300` `replace_into_force_info` — one entity, `reserve++` at `:297`.
- `hc_dstry.c:343-346` / `fw_dstry.c:332-335` — EECH declines to charge a loss for removing
  something that is no longer `INT_TYPE_ALIVE`.

Then decide whether CRASH alone, CRASH+DEAD, or a unit-category test is the faithful trigger,
and whether the existing ring-buffer regen queue is the right sink. Cite the C source.

## Guardrails

- Epic #17 P3 deliberately did **not** change this — it is a behavioural economy change, not a
  settlement fix, and belongs in its own package with its own EECH grounding.
- P3 *did* make the related safety guarantee: a **cleanup-generated** death is not counted as a
  fresh combat loss and does not enqueue regeneration. Do not undo that when fixing this.
- Needs a regression fixture built from the real capture, not an invented event.
