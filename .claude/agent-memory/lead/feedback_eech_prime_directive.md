---
name: eech-prime-directive
description: Treat user complaints about campaign behaviour as reports of divergence from the EECH C source, never as requests for a tuned fix
metadata:
  type: feedback
---

A user complaint like "captures are too slow" or "it's too fixed-wing" is a bug report
of MISALIGNMENT with the EECH C source, not a change request. Never patch the symptom
with an invented threshold, timeout, spacing or capacity constant.

**Why:** this repo is a faithful port of EECH, not a game design. Any value not traceable
to a line in `E:\eech_source_code` is a latent bug by the project's own Prime Directive
(CLAUDE.md). Tuning-by-feel is how the port drifts.

**How to apply:** for any behavioural change, make the bot (1) find the governing C code,
(2) read it, (3) match it, (4) cite file:line in the code comment. Put this constraint in
every implementation brief. Where DCS genuinely cannot reproduce EECH, require the closest
faithful proxy plus a documented divergence in the module header. Use the `eech-fidelity`
skill. Known unfixed misalignments are listed in CLAUDE.md — fix by realigning, never by
re-tuning.
