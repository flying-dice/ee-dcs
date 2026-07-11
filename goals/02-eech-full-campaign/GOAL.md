# Goal: Full EECH campaign feature parity

**Status:** active
**Created:** 2026-07-04
**Owner:** Jonathan Turnock

## Outcome

The dynamic mission plays out like a complete EECH campaign session — both sides field credible
air and ground forces with weapons, react to each other's actions, sustain losses and replace
them, repair damaged bases, and fight to a meaningful conclusion. Every major EECH campaign
system has a corresponding DCS Lua module. A player jumping in mid-mission should feel like
they've joined an ongoing war, not a scripted sequence.

## Acceptance criteria

### Combat effectiveness
- [x] **Weapon payloads** — all spawned aircraft carry correct loadouts (missiles, bombs, gun);
      no aircraft spawn with empty pylons (`payloads.lua`)
- [x] **SEAD waves** — dedicated SEAD packages target enemy SAM/AAA groups; mirrors
      `create_sead_tasks` (12 min campaign / 3 min offset) (`cas_bai_sead.lua`)
- [x] **CAS missions** — close air support attacks ground units near the frontline; mirrors
      `create_cas_tasks` (15 min / 0 s offset) (`cas_bai_sead.lua`)
- [x] **BAI missions** — battlefield air interdiction targets enemy ground columns in transit;
      mirrors `create_bai_tasks` (20 min / 5 min offset) (`cas_bai_sead.lua`)
- [x] **OCA Sweep** — offensive counter-air sweep against enemy airbases; mirrors
      `create_oca_sweep_tasks` (30 min / 1.5 min offset) (`cas_bai_sead.lua`)
- [x] **Artillery support** — own artillery units fire on enemy frontline and keysite targets;
      mirrors `create_artillery_strike_tasks` (15 min / 45 s) (`cas_bai_sead.lua`)

### Rotary-wing war (EECH is primarily a helicopter sim — the main bulk of gameplay)
- [x] **Attack-helicopter anti-armour** — (2026-07-05) attack-heli sections (AH-64D/Mi-24V, ATGM)
      hunt enemy frontline ground groups; the core EECH mission, higher tempo than fixed-wing
      (`heli_war.lua schedule_anti_armour`).
- [x] **Hunter-killer armed recon** — (2026-07-05) attack helis patrol the frontline sector,
      engaging ground AND air (heli-vs-heli combat) (`heli_war.lua schedule_hunter_killer`).
- [x] **Attack-heli escort** — (2026-07-05) attack helis shepherd vulnerable troop-insertion helis
      into hostile airspace (`heli_war.lua spawn_escort`, wired from `troop.lua`).
- [x] **Non-airbase keysites** — (2026-07-05) depot/fuel/radar installations behind each base as
      static keysites (ground_strike + recon flags), so keysite-strike & artillery hit them while
      OCA-strike stays airfield-only — distinct strike target sets (`installations.lua`).

### Reaction system
- [x] **BARCAP / intercept** — when an enemy Strike/OCA-Strike/OCA-Sweep/Recon group spawns,
      a defensive CAP and BARCAP scramble at the threatened base; mirrors
      `create_reaction_to_offensive_keysite_task_assigned` (`reaction.lua`)
- [x] **CAP duration enforced** — CAP/BARCAP groups self-destruct after 1800 s (30 × ONE_MINUTE);
      mirrors reaction.c lines 248/298 (`reaction.lua`)
- [x] **BDA chain** — completed strikes trigger a BDA helicopter; BDA completion spawns
      OCA_STRIKE + OCA_SWEEP + T.I. or GROUND_STRIKE depending on efficiency;
      mirrors `create_reaction_to_strike/recon_task_completed` (`reaction.lua`)
- [~] **Escort escalation** — escort package size is phase-scaled; reaction.c itself contains no
      escort-size scaling (that lives in taskgen). Reaction chain fully faithful otherwise.
      (2026-07-05: reaction.lua rewritten — completion-on-RTB, correct-base defense, SEAD gate.)

### Logistics and sustainability
- [x] **Unit regen queue** — destroyed groups are queued (ring buffer, size 5) and respawned
      at friendly bases on a 60 s tick; mirrors `rg_updt.c` (`regen.lua`)
- [x] **Reserve pool** — each side has finite aircraft counts per base; no task spawns when
      reserves exhausted; mirrors `force_info_reserve_hardware` (`supply.lua`)
- [x] **FW / HC transfer** — aircraft repositioned from idle-surplus bases to threatened bases;
      mirrors `create_fixed_wing/helicopter_transfer_tasks` (`transfer.lua`)
- [x] **Base repair** — neutralised bases auto-recover health; ammo/fuel cycle at 60 s;
      efficiency (h×0.5 + ammo×0.25 + fuel×0.25) drives T.I. and reaction thresholds;
      mirrors `ks_updt.c` (`keysite_repair.lua`)
- [x] **Supply → strength integration** — (2026-07-05) strength is now a live census of fielded
      hardware (`fc_updt.c` force_percentage); finite per-side reserve pool, no production, RTB
      recycle. Aircraft attrition now directly drives strength and the win condition.

### Intelligence / fog of war
- [x] **Fog of war decay and recon** — per-base per-side FOW decays every 30 s; friendly units
      grant FOW based on proximity using per-category recon radii (airplane 20 km / heli 10 km /
      ground 3 km); mirrors `sector.c` (`fog_of_war.lua`)
- [x] **Task FOW gates** — BAI requires FOW > 0.5×max; SEAD/OCA/Arty require ≥ 0.25×max;
      T.I. requires ≥ 0.20×max; CAS has no gate; mirrors highlevl.c thresholds
- [x] **Troop insertion** — helicopter inserts infantry at weakened enemy bases (efficiency < 0.80);
      captured after 5 min proximity; mirrors `create_troop_insertion_tasks` (`troop.lua`)
- [x] **Dedicated recon sorties** — (2026-07-05) new `recon.lua`; CAS/BAI/SEAD/OCA FOW gate is now
      the EECH strike-vs-recon FORK — fogged targets spawn a recon that reveals them (aimed at the
      sector base so FOW actually rises), instead of being dropped. Self-healing loop restored.

### Ground campaign
- [x] **Column advance / retreat** — armoured columns advance to nearest enemy base, retreat
      when own base falls; 12 min / 12 s offset; mirrors `create_advance_and_retreat_tasks`
      (`ground_forces.lua`)
- [x] **Infantry patrol** — infantry squads patrol owned bases; 5 min / 5 s offset;
      mirrors `create_troop_patrol_tasks` (`troop.lua`)
- [x] **Multiple simultaneous columns** — (2026-07-05) replaced the single column with a STANDING
      FRONTLINE registry (`S.ground_groups`): one company per frontline base, seeded at OOB from the
      "vehicle" reserve, with keysites-as-nodes advance/retreat, occupancy deconfliction, and
      reserve-drawn reinforcement (ground regen). Road-node graph itself is a DCS structural limit.

### Campaign feel
- [x] **Frontline detection** — per-base frontline flag computed every 120 s; used by CAS/BAI
      targeting; mirrors `ai_fline.c` (`frontline.lua`)
- [x] **Influence maps** — 4-layer imap (BASE_DISTANCE, AIR_DEFENCE, SURFACE_DEFENCE, IMPORTANCE)
      updated every 120 s with 20 s stagger; drives all scoring formulas (`imap.lua`)
- [x] **Mission debrief message** — (2026-07-05) `win_condition.finish()` shows a full campaign
      debrief (winner, reason, bases + strength both sides) via `trigger.action.outText`.
- [x] **Phase announcement to players** — (2026-07-05) phase transitions now emit
      `trigger.action.outText` in-game (BLUE/RED strength) alongside the `env.info()` log.

## Constraints & guardrails

- Mission scripting environment only: `env.info()` not `log.info()`
- All aircraft spawned in-air at cruise altitude — never TakeOffParking
- Airbase filter: `ab:getDesc().category == Airbase.Category.AIRDROME`
- Verified unit type names only — query live DB before adding any new type
- Each new system goes in its own `.lua` file with header naming the EECH source file(s)
- Do not break existing modules; build must show 0 warnings after every change
- Any change to campaign AI constants must be verified against EECH C source before committing
- `run_*` single-shot exports (`attack_waves.run_strike`, `cas_bai_sead.run_oca_sweep`,
  `troop.run_troop_insertion`) exist for reaction.lua — never replace them with scheduler calls

## Autonomy level

Full autonomy (same as goal-01). User is not in the mission. Agent may:
- Build, inject, iterate, and read DCS logs at will
- Create any new module files needed
- Modify existing modules to wire in new systems

Ask before: changing the public `game_loop.start()` interface or restructuring the bundle
in a way that would break how the mission editor trigger calls the script.

## Context & links

- EECH source: `E:\eech_source_code`
- Project root: `C:\Users\jonat\DCSStudio\my-test-mod`
- Build: `lua-cargo build` → `dist/dynamic-mission-test.lua`
- Inject: `dcs_eval` → `net.dostring_in('server', 'dofile("...dist/dynamic-mission-test.lua")')`
- GitLab for tooling issues: https://gitlab.beluga-sirius.ts.net/flying-dice/dcs-studio
- Fidelity journal: `.claude/projects/.../memory/project_eech_campaign.md`

## Remaining work (priority order)

Most of the original backlog + a full gap analysis (24 findings) were closed 2026-07-05 across
Clusters A–F (force economy, recon loop, reaction chain, standing ground frontline, repair/SEAD/FOW,
player-facing/criteria) — each adversarially reviewed, build clean (20 modules, 0 warnings; check:
22 files, no findings). See `2026-07-05-close-all-gaps.journal.md`. What remains:

1. **Cluster G — non-airbase keysites** — baked-scenario static installations (bridges/depots/
   factories/radar) as keysites with `oca_target`/`ground_strike_target`/`recon_target` flags, so
   create_keysite_strike and create_oca_strike hit genuinely distinct target sets (today both are
   airbase-only). The one substantive open fidelity gap; own session (invasive to targeting/capture).
2. **Live end-to-end validation** — port builds clean but was never exercised in a running mission
   (DCS at main menu all session). Inject and verify campaign behaviour in a live MP session.
3. **SEAD anti-radiation loadout** — SEAD tasking is wired; swap in a HARM/Kh-25MP payload once the
   weapon CLSIDs are verified against the live DCS DB (guardrail — no unverified CLSIDs).
4. **Structural limits (cannot be closed in DCS)** — road-node adjacency graph (ground movement),
   INT_TYPE_FRONTLINE echelon integer (BAI target selection), per-scenario campaign-criteria data.
   Documented as faithful proxies.
