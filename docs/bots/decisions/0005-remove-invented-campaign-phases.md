# ADR 0005: Remove invented elapsed-time campaign phases

## Context

The DCS adapter exposed `early`, `mid` and `late` labels at 15 and 35 minutes. The labels were announced to players, persisted and included in F10 reports, but had no behavioural consumer. The retained EECH source has session elapsed time and independently scheduled high-level AI functions; it does not define an elapsed-time campaign phase state that changes campaign behaviour. `aphavoc/source/ai/highlevl/highlevl.c:181-285` schedules the same generators for the session, with campaign versus skirmish selecting their intervals at startup. Its elapsed-time reads align scheduler execution rather than select a strategic phase.

EECH does provide the general `CAMPAIGN_TRIGGER_TIME_DURATION` script trigger (`aphavoc/source/entity/system/en_types/en_force.h:206-228`, evaluated in `aphavoc/source/ai/parser/parsgen.c:2637-2679`). A scenario author can use that facility to fire a data-driven event, including changing task-generation flags. It is optional scenario scripting and does not establish named engine phases. No campaign data in the retained source tree defines the adapter's early/mid/late sequence.

The labels therefore implied escalation that the port did not implement and attributed a mechanic to EECH without source evidence.

## Decision

Remove the phase field, thresholds, transition announcements, persistence field and report text. Retain campaign elapsed time for operational logging and save continuity.

Campaign evolution remains driven by ported EECH state: task generation, importance and threat maps, fog of war, keysite efficiency, reserves, reaction chains, capture and victory conditions. New behaviour must cite its EECH source or be explicitly documented as a DCS adapter requirement.

## Consequences

Players no longer receive misleading timed phase announcements. Existing saves remain readable because the schema validator ignores extra fields, including the retired `phase` field. Status and F10 reports contain only state that has campaign meaning.
