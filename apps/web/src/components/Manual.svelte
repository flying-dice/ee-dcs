<script lang="ts">
// ── Manual: full-screen operations manual (old-school game-manual style) ───────
// Covers the whole campaign — what it is, how to play, how to win, the mechanics
// under the hood — plus the Mission-Editor authoring reference. Content is grounded
// in the port's README + modules (EECH-faithful: keysites, reserves, fog/recon,
// reaction chains, the ground/heli war, the economy, capture, win condition).
import { createEventDispatcher } from "svelte";
import type { KeysiteType } from "../lib/types";

export let typeColors: Record<KeysiteType, string> = {} as Record<
	KeysiteType,
	string
>;
const dispatch = createEventDispatcher<{ close: void }>();

const CONTENTS = [
	{ n: "01", id: "briefing", title: "Briefing", sub: "The dynamic campaign" },
	{ n: "02", id: "play", title: "How to play", sub: "Tasking & your impact" },
	{
		n: "03",
		id: "missions",
		title: "Mission types",
		sub: "The tasks that run the war",
	},
	{ n: "04", id: "win", title: "How to win", sub: "Victory conditions" },
	{
		n: "05",
		id: "machine",
		title: "The war machine",
		sub: "Mechanics under the hood",
	},
	{
		n: "06",
		id: "editor",
		title: "Editing the theatre",
		sub: "The Mission Editor reference",
	},
	{ n: "07", id: "acronyms", title: "Acronyms", sub: "Appendix & glossary" },
];

// Mission taxonomy — the EECH manual's task list, matched to what the port actually flies.
const MISSIONS = [
	{
		m: "Recon",
		who: "Fixed-wing",
		d: "A recon overflight reveals a fogged sector so a strike can be planned against it. (Rotary recon is the BDA sortie below.)",
	},
	{
		m: "CAP / BARCAP",
		who: "Fighters",
		d: "Combat / barrier air patrol, scrambled to defend a threatened base or screen a strike corridor.",
	},
	{
		m: "CAS",
		who: "Rotary",
		d: "Close air support — attack helicopters hitting enemy armour along the front line.",
	},
	{
		m: "BAI",
		who: "Rotary",
		d: "Battlefield air interdiction — ground forces and columns behind the immediate front.",
	},
	{
		m: "Ground / keysite strike",
		who: "Fixed-wing",
		d: "Degrades an enemy installation’s efficiency — factories, refineries, radars, command posts.",
	},
	{
		m: "OCA strike",
		who: "Fixed-wing",
		d: "Offensive counter-air against enemy airfields, to suppress their sortie rate.",
	},
	{
		m: "SEAD",
		who: "Fixed-wing",
		d: "Suppression of enemy air defences — hunts the radar / EWR emitters before a strike goes in.",
	},
	{
		m: "BDA",
		who: "Rotary",
		d: "Battle damage assessment after a strike; the report generates the next round of tasking.",
	},
	{
		m: "Troop insertion",
		who: "Rotary",
		d: "Air-mobile assault that captures a neutralised installation once its defence collapses.",
	},
	{
		m: "Escort",
		who: "Rotary",
		d: "Gunship sections shielding the vulnerable troop-insertion flights to and from the objective.",
	},
];

// Appendix glossary.
const ACRONYMS: [string, string][] = [
	[
		"Comanche",
		"RAH-66 — Enemy Engaged’s Blue-side namesake. In DCS you fly the AH-64D for Blue Force.",
	],
	[
		"Hokum",
		"Ka-50 / Ka-52 — the Red-side namesake. In DCS you fly the Mi-24V for Red Force.",
	],
	[
		"Keysite",
		"Any strikeable / capturable installation — airbase, FARP, factory, refinery, port, radar, power, command, supply depot, or fuel depot.",
	],
	["FARP", "Forward Arming & Refuelling Point — a forward helicopter base."],
	[
		"FLOT",
		"Forward Line of Own Troops — the front line, where blue and red territory meet.",
	],
	["CAP / BARCAP", "Combat / Barrier Air Patrol — defensive fighter cover."],
	[
		"CAS / BAI",
		"Close Air Support / Battlefield Air Interdiction — hitting ground forces at and behind the front.",
	],
	["OCA", "Offensive Counter-Air — strikes against enemy airfields."],
	["SEAD", "Suppression of Enemy Air Defences."],
	["BDA", "Battle Damage Assessment — the recon that follows a strike."],
	["EWR", "Early-Warning Radar — the emitter a radar keysite represents."],
	[
		"Fog of war",
		"Sectors with stale reconnaissance; lifted by recon or friendly presence.",
	],
];

// "Under the hood" subsystems.
const SYSTEMS = [
	{
		t: "Keysites & territory",
		b: "Everything is built from <b>keysites</b> — airfields, FARPs, factories, refineries, ports, radars, power stations, command posts, supply depots, and fuel depots. Each belongs to a side; the <b>front</b> is simply where blue and red territory meet. Take ground and the front moves.",
	},
	{
		t: "Force strength",
		b: "A running tally of the aircraft and vehicles each side still fields, updated live and read out in the debrief. Watch it swing as bases trade sorties and the front moves — it is the pulse of how each force is holding up.",
	},
	{
		t: "Reserves, recycle — no production",
		b: "Each side draws finite <b>per-role reserve pools</b> from its bases. Every spawn <b>consumes</b> from the pool; a jet that lands is <b>recycled</b> back in. There is no free production — hardware returns only by landing safely, so wear a side’s pools down and its sortie rate falls with them.",
	},
	{
		t: "The economy",
		b: "<b>Factories produce ammo, refineries &amp; ports produce fuel.</b> Producers accumulate supply as cargo crates, which <b>transport aircraft physically fly</b> to restock forward bases and replace lost hardware. Bomb an enemy factory and that side slowly starves.",
	},
	{
		t: "Fog of war & the recon fork",
		b: "Per-base fog decays over time and is lifted by friendly units nearby. A strike on a <b>fogged</b> target isn’t thrown away — it launches a <b>recon sortie</b> first, and the strike follows once the recon returns. EECH’s self-healing strike-vs-recon loop.",
	},
	{
		t: "Reaction chains",
		b: "Detect an incoming strike/OCA/recon and the threatened base <b>scrambles CAP/BARCAP</b>. A completed strike sends a <b>BDA helicopter</b>; its report branches into follow-on strikes, fighter sweeps, or a troop insertion — the EECH task-completed chain.",
	},
	{
		t: "The air war",
		b: "Fixed-wing is scarce and flies from <code>airbase</code>s only — OCA strikes, keysite strikes, SEAD. The <b>helicopter war is the core</b>: attack-heli sections fly <b>CAS</b> and <b>BAI</b> against the frontline armour (and will take on enemy helicopters), while gunships <b>escort</b> the vulnerable troop-insertion flights.",
	},
	{
		t: "The ground front & capture",
		b: "One armoured company per frontline base <b>advances</b> toward the nearest enemy base and <b>falls back</b> to a friendly base when its own strength drops below half. Strikes grind a base’s efficiency down; below the minimum it turns <b>capturable</b>, and a troop insertion that reaches it <b>seizes</b> it — flipping the front.",
	},
	{
		t: "Tasking cadence",
		b: "The high command runs on a steady rhythm of staggered cycles — recon, strikes, reactions, the ground push and resupply each on their own beat, so the war keeps generating new sorties around the clock. A campaign or skirmish setting sets the overall tempo.",
	},
];

const TYPES: { key: KeysiteType; eech: string; bases: string; role: string }[] =
	[
		{
			key: "airbase",
			eech: "AIRBASE",
			bases: "fixed-wing + heli",
			role: "Draw over a real DCS airfield. The few fields fixed-wing flies from.",
		},
		{
			key: "farp",
			eech: "FARP",
			bases: "helicopters",
			role: "Forward heli base spawned at the zone. The rotary war launches from these.",
		},
		{
			key: "factory",
			eech: "FACTORY",
			bases: "—",
			role: "Produces ammo. Destroy it and the enemy can’t rearm or replace losses.",
		},
		{
			key: "refinery",
			eech: "OIL_REFINERY",
			bases: "—",
			role: "Produces fuel. Fuel-storage / tank farms map here too.",
		},
		{
			key: "port",
			eech: "PORT",
			bases: "—",
			role: "Fuel logistics (coastal). Strategic strike target.",
		},
		{
			key: "radar",
			eech: "RADIO_TRANSMITTER",
			bases: "—",
			role: "Real EWR emitter — a SEAD target and detection node.",
		},
		{
			key: "power",
			eech: "POWER_STATION",
			bases: "—",
			role: "Strategic strike target.",
		},
		{
			key: "command",
			eech: "MILITARY_BASE",
			bases: "—",
			role: "Command / military base. Strategic strike + capture target.",
		},
		{
			key: "depot",
			eech: "MILITARY_BASE",
			bases: "—",
			role: "Supply and ammunition depot. Strategic strike + capture target.",
		},
		{
			key: "fuel",
			eech: "OIL_REFINERY",
			bases: "—",
			role: "Fuel-storage depot. Strike and reconnaissance target.",
		},
	];

const EDITS = [
	{
		verb: "Add any keysite",
		how: "Draw a trigger zone, name it <code>type_label</code> (e.g. <code>factory_kutaisi</code>), and set its colour blue or red. That’s the whole contract.",
	},
	{
		verb: "Add an airbase",
		how: "Draw an <code>airbase_name</code> zone <b>over a real DCS airfield</b> and colour it. An airfield with no <code>airbase</code> zone is left out.",
	},
	{
		verb: "Add a FARP",
		how: "Draw a <code>farp_name</code> zone in friendly territory — a forward heli base is created at the zone centre.",
	},
	{
		verb: "Move or resize",
		how: "Drag the zone or change its radius. The keysite location follows the zone centre.",
	},
	{
		verb: "Switch side",
		how: "Recolour the zone — blue-dominant → BLUE, red-dominant → RED.",
	},
	{
		verb: "Remove a keysite",
		how: "Delete its zone. (Removing an <code>airbase</code> zone drops that airfield.)",
	},
];

function onKey(e: KeyboardEvent): void {
	if (e.key === "Escape") dispatch("close");
}
function onBackdrop(e: MouseEvent): void {
	if (e.target === e.currentTarget) dispatch("close");
}
function goto(id: string): void {
	document
		.getElementById("ch-" + id)
		?.scrollIntoView({ behavior: "smooth", block: "start" });
}
</script>

<svelte:window on:keydown={onKey} />

<!-- svelte-ignore a11y-click-events-have-key-events a11y-no-static-element-interactions -->
<div class="backdrop" on:click={onBackdrop} role="presentation">
  <article class="manual" role="dialog" aria-modal="true" aria-label="Operations manual">
    <button class="close" title="Close (Esc)" on:click={() => dispatch('close')}>✕</button>

    <header class="hero">
      <div class="eyebrow">Operations Manual</div>
      <h1>Enemy Engaged<span class="sep">·</span>Comanche Hokum</h1>
      <div class="issue">Dynamic Campaign for DCS World — Field Handbook</div>
      <p class="lede">
        This is not a scripted mission. It is a <b>living AI-vs-AI war</b> — the Enemy Engaged
        dynamic campaign, ported faithfully into DCS. Strikes, recon, reactive intercepts, a
        standing ground front, a helicopter war and a supply economy all run on their own. You
        drop into a war already in progress.
      </p>
    </header>

    <!-- contents -->
    <nav class="toc" aria-label="Contents">
      <div class="toc-h">Contents</div>
      {#each CONTENTS as c}
        <button class="toc-row" on:click={() => goto(c.id)}>
          <span class="toc-n">{c.n}</span>
          <span class="toc-t">{c.title}</span>
          <span class="toc-dots"></span>
          <span class="toc-s">{c.sub}</span>
        </button>
      {/each}
    </nav>

    <!-- 01 briefing -->
    <section class="ch" id="ch-briefing">
      <div class="ch-head"><span class="ch-n">01</span><h2>Briefing</h2></div>
      <p>
        On an otherwise <b>empty map</b>, the campaign takes the theatre’s airfields, splits them
        between <b class="fr">Blue Force</b> and <b class="ho">Red Force</b>, and boots an entire
        war from script — no hand-placed units. (On a bare map it scopes to the densest cluster of
        fields; in a generated <code>.miz</code> it uses exactly the ones you zoned.) The two sides
        fight over <b>keysites</b> (installations): the airfields and FARPs they fly from, and the
        factories, refineries, radars and command posts that feed and blind each other.
      </p>
      <p>
        As in Enemy Engaged, this is <b>continuous warfare independent of player action</b> —
        the AI pursues its own tasking and there are <b>no scripted outcomes</b>. The war is
        self-sustaining and self-healing: it reconnoitres what it can’t see, defends what’s
        threatened, resupplies what’s short, and reinforces what’s losing. Every rhythm and
        ratio is true to Enemy Engaged.
      </p>
    </section>

    <!-- 02 how to play -->
    <section class="ch" id="ch-play">
      <div class="ch-head"><span class="ch-n">02</span><h2>How to play</h2></div>
      <div class="two">
        <div>
          <h3>Fly in it (multiplayer)</h3>
          <p>In multiplayer you take a slot and fly as a <b>first-class combatant</b>, not a spectator. The campaign <b>never destroys or recycles your aircraft</b>, and your kills, your losses and the recon you bring back feed the same economy the AI fights on — fly CAS for the side that’s pushing, hunt the armour column closing on a base, or strike the factory that keeps the enemy armed. What you do to the war stays done.</p>
        </div>
        <div>
          <h3>Build one (this tool)</h3>
          <p>Use this generator to turn any real-world region into a theatre: paint resolution-5 H3 cells Blue or Red as rear or close territory, choose each side’s main airbase, and it places real airfields and infrastructure as keysites. FARPs and radar use close territory; producers and command sites use rear territory. It then ships a playable <code>.miz</code> with the campaign baked in. Open it in DCS and the war starts. See <button class="ilink" on:click={() => goto('editor')}>Editing the theatre</button> to customise it.</p>
        </div>
      </div>
      <p class="note">Tip: the side that owns more producers and forward FARPs sustains a higher sortie tempo. If your side is losing, the highest-leverage targets are the enemy’s <b>factories and refineries</b> — starve the economy and the front follows.</p>

      <h3 class="sh">F10 operational picture</h3>
      <p>
        The mission ships its own coalition-safe operational picture on the DCS <b>F10 map</b>.
        It marks friendly bases and installations, objectives, the FLOT, queued and active air
        tasks, and the main ground formations. Enemy detail appears only as your side gains
        intelligence; unknown strength, supply, and movements stay hidden. The picture refreshes
        as the campaign changes, so completed missions and lost contacts clear from the map.
      </p>
      <p>
        Open the radio menu and choose <b>Campaign</b> for coalition reports: <b>Situation</b>,
        <b>Air Tasking</b>, <b>Logistics &amp; Regen</b>, <b>Intelligence</b>, and
        <b>Campaign Statistics</b>. These reports use the same live campaign state as the map and
        are visible only to your coalition. Individual vehicle and building pins are deliberately
        omitted from the default view to keep the map readable.
      </p>
    </section>

    <!-- 03 mission types -->
    <section class="ch" id="ch-missions">
      <div class="ch-head"><span class="ch-n">03</span><h2>Mission types</h2></div>
      <p>The war is fought as discrete <b>sorties</b>. These are the tasks the campaign generates and rates each cycle — the AI flies them, and in multiplayer so can you.</p>
      <div class="missions">
        {#each MISSIONS as x}
          <div class="mrow">
            <span class="mm">{x.m}</span>
            <span class="mw" class:fw={x.who === 'Fixed-wing'} class:rot={x.who === 'Rotary'}>{x.who}</span>
            <span class="md">{x.d}</span>
          </div>
        {/each}
      </div>
    </section>

    <!-- 04 how to win -->
    <section class="ch" id="ch-win">
      <div class="ch-head"><span class="ch-n">04</span><h2>How to win</h2></div>
      <p>A side wins by either:</p>
      <div class="wincards">
        <div class="wc">
          <div class="wc-k">Objectives</div>
          <p><b>Seize the enemy’s designated keysites.</b> Each side is assigned a set of enemy objective keysites it must capture. A base is worn below the minimum efficiency by strikes, then an <b>air-mobile troop insertion</b> that reaches the neutralised base seizes it — flipping it to your side.</p>
        </div>
        <div class="wc">
          <div class="wc-k">Collapse</div>
          <p><b>Break the enemy’s ability to fly.</b> The war also ends when a side is left with <b>no usable airbase</b>, or <b>no flyable combat helicopters</b> — bled out in the air, on the ground, and by starving its economy.</p>
        </div>
      </div>
      <p class="note">When either condition trips, the campaign broadcasts a full <b>debrief</b> in-game and the war concludes.</p>
    </section>

    <!-- 05 the war machine -->
    <section class="ch" id="ch-machine">
      <div class="ch-head"><span class="ch-n">05</span><h2>The war machine</h2></div>
      <p>The systems that keep the war moving on its own — read them to understand what your sorties are really feeding into.</p>
      <div class="sys">
        {#each SYSTEMS as s}
          <div class="scard">
            <h3>{s.t}</h3>
            <p>{@html s.b}</p>
          </div>
        {/each}
      </div>
    </section>

    <!-- 06 editing -->
    <section class="ch" id="ch-editor">
      <div class="ch-head"><span class="ch-n">06</span><h2>Editing the theatre</h2></div>
      <p>
        The whole order of battle is expressed as <b>trigger zones</b> in the Mission Editor —
        open the generated <code>.miz</code> and edit freely. No scripting required.
      </p>
      <p>To resume designing in this tool, use <b>Save design (GeoJSON)</b> and later
        <b>Load design (GeoJSON)</b>. That file preserves painted territory, selected main
        airbases, site choices and generator settings. A generated <code>.miz</code> is for
        playing or editing in DCS; it is not a project save for this generator.</p>

      <h3 class="sh">Every keysite is a zone</h3>
      <div class="contract">
        <div class="cc"><span class="cc-k">Colour</span><span class="cc-v">→ side</span><span class="cc-d">blue-dominant → <b class="fr">BLUE</b>, red-dominant → <b class="ho">RED</b></span></div>
        <div class="cc"><span class="cc-k">Name</span><span class="cc-v">→ type</span><span class="cc-d">first word before <code>_</code>, e.g. <code>airbase_batumi</code></span></div>
        <div class="cc"><span class="cc-k">Centre</span><span class="cc-v">→ location</span><span class="cc-d">an <code>airbase</code> zone binds to the DCS airfield it covers</span></div>
      </div>

      <h3 class="sh">Keysite types</h3>
      <div class="types">
        {#each TYPES as t}
          <div class="trow">
            <span class="sw" style="background:{typeColors[t.key]}"></span>
            <span class="tk">{t.key}</span>
            <span class="te">{t.eech}</span>
            <span class="tb" class:on={t.bases !== '—'}>{t.bases}</span>
            <span class="tr">{t.role}</span>
          </div>
        {/each}
      </div>

      <h3 class="sh">Common edits</h3>
      <div class="cards">
        {#each EDITS as e}
          <div class="card">
            <span class="c tl"></span><span class="c tr2"></span><span class="c bl"></span><span class="c br"></span>
            <h4>{e.verb}</h4>
            <p>{@html e.how}</p>
          </div>
        {/each}
      </div>

      <h3 class="sh">Make a keysite matter</h3>
      <p>A keysite’s health <b>is its real objects</b>. The campaign <b>registers the static objects you place inside its circle</b> (warehouses, fuel tanks, hangars…) as that site’s assets — its health is the fraction still standing, and strikes grind it down to neutralised. Fill a factory’s zone with statics and it becomes something you can bomb flat. Leave a zone empty and the campaign stands up a default building complex and garrison there, so the keysite still has something to fight over — place your own statics to control exactly what’s inside.</p>

      <h3 class="sh">Keep it EECH-shaped</h3>
      <ul class="ticks">
        <li><b>FARPs outnumber airbases ~3:1</b> — the rotary war is the main event.</li>
        <li>Producers <b>few and rear</b>; nearest opposing bases <b>~50–100&nbsp;km apart</b> (helicopter range).</li>
        <li>Rough counts/side: airbase <b>1–2</b>, farp 3–6, factory 1–2, the rest ~1–2 each. (More than 2 airbases tips it into a fixed-wing air war.)</li>
      </ul>

      <h3 class="sh">Run it</h3>
      <ol class="run">
        <li><b>Save</b>, then <b>start the mission</b> — the baked-in campaign boots automatically.</li>
        <li>Boot log prints <code>theatre from zones: N airbases, M FARPs, K keysites</code>.</li>
        <li>Every base and keysite is <b>labelled on the F10 map</b>; captures and losses update it live.</li>
      </ol>
    </section>

    <!-- 07 acronyms -->
    <section class="ch" id="ch-acronyms">
      <div class="ch-head"><span class="ch-n">07</span><h2>Acronyms</h2></div>
      <div class="glossary">
        {#each ACRONYMS as [term, def]}
          <div class="grow"><span class="gt">{term}</span><span class="gd">{def}</span></div>
        {/each}
      </div>
    </section>

    <footer class="foot">
      A faithful reprise of the Enemy Engaged: Comanche vs Hokum dynamic campaign, brought to DCS
      World — this handbook follows the original in spirit, in its own words. Advanced configuration
      is covered in the project README.
    </footer>
  </article>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 1000;
    background: rgba(3, 8, 7, 0.85);
    backdrop-filter: blur(3px);
    display: flex;
    justify-content: center;
    align-items: flex-start;
    padding: 4vh 16px;
    overflow-y: auto;
  }
  .manual {
    position: relative;
    width: 100%;
    max-width: 900px;
    background: linear-gradient(180deg, rgba(10, 22, 19, 0.98), rgba(7, 16, 14, 0.98));
    border: 1px solid var(--edge-hot);
    border-radius: 4px;
    box-shadow: 0 24px 80px rgba(0, 0, 0, 0.6), 0 0 0 1px rgba(92, 242, 166, 0.06) inset;
    color: var(--ink);
    padding-bottom: 8px;
  }
  .close {
    position: absolute;
    top: 12px; right: 12px;
    width: 30px; height: 30px;
    padding: 0; font-size: 1rem;
    color: var(--phosphor);
    background: rgba(8, 19, 17, 0.9);
    border: 1px solid var(--edge);
    border-radius: 3px; z-index: 2;
  }
  .close:hover { color: var(--hostile); border-color: var(--hostile); }

  /* hero */
  .hero {
    padding: 34px 38px 24px;
    border-bottom: 1px solid var(--edge);
    background: radial-gradient(130% 100% at 0% 0%, rgba(92, 242, 166, 0.08), transparent 60%);
  }
  .eyebrow { font-family: var(--font-hud); font-size: 0.72rem; letter-spacing: 0.34em; text-transform: uppercase; color: var(--amber); }
  .hero h1 {
    margin: 12px 0 6px;
    font-family: var(--font-hud);
    font-size: 2.05rem; font-weight: 400; letter-spacing: 0.02em; line-height: 1.05;
    color: var(--phosphor-hot); text-shadow: var(--glow);
  }
  .hero h1 .sep { color: var(--amber); margin: 0 10px; }
  .issue { font-family: var(--font-hud); font-size: 0.74rem; letter-spacing: 0.18em; text-transform: uppercase; color: var(--phosphor-dim); margin-bottom: 14px; }
  .lede { margin: 0; max-width: 68ch; font-size: 0.94rem; line-height: 1.65; }

  /* contents */
  .toc { padding: 18px 38px 20px; border-bottom: 1px solid var(--edge); }
  .toc-h { font-family: var(--font-hud); font-size: 0.72rem; letter-spacing: 0.2em; text-transform: uppercase; color: var(--phosphor-dim); margin-bottom: 8px; }
  .toc-row {
    display: flex; align-items: baseline; gap: 12px; width: 100%;
    padding: 7px 6px; background: transparent; border: 0; border-bottom: 1px solid rgba(92, 242, 166, 0.07);
    text-align: left; cursor: pointer;
  }
  .toc-row:hover { background: var(--accent-dim); }
  .toc-n { font-family: var(--font-hud); color: var(--amber); font-size: 0.82rem; }
  .toc-t { font-family: var(--font-hud); color: var(--phosphor-hot); letter-spacing: 0.04em; font-size: 0.92rem; }
  .toc-dots { flex: 1; border-bottom: 1px dotted var(--edge-hot); transform: translateY(-3px); }
  .toc-s { color: var(--muted); font-size: 0.8rem; }

  /* chapters */
  .ch { padding: 26px 38px; border-bottom: 1px solid var(--edge); }
  .ch:last-of-type { border-bottom: 0; }
  .ch-head { display: flex; align-items: baseline; gap: 14px; margin-bottom: 14px; }
  .ch-n {
    font-family: var(--font-hud); font-size: 1.5rem; color: var(--amber);
    opacity: 0.55; letter-spacing: 0.05em;
  }
  .ch-head h2 { margin: 0; font-family: var(--font-hud); font-size: 1.35rem; font-weight: 400; letter-spacing: 0.02em; color: var(--phosphor); text-shadow: var(--glow); }
  .ch p { margin: 0 0 12px; font-size: 0.9rem; line-height: 1.65; max-width: 70ch; }
  .ch h3 { margin: 0 0 8px; font-family: var(--font-hud); font-size: 0.98rem; font-weight: 400; letter-spacing: 0.03em; color: var(--phosphor-hot); }
  .sh { margin-top: 22px !important; padding-top: 4px; border-top: 1px solid var(--edge); }
  .note { font-size: 0.83rem !important; color: var(--muted); border-left: 2px solid var(--edge); padding-left: 12px; }
  code { font-family: var(--font-hud); font-size: 0.86em; color: var(--phosphor-hot); background: rgba(92, 242, 166, 0.08); padding: 1px 5px; border-radius: 2px; }
  .fr { color: var(--friendly); }
  .ho { color: var(--hostile); }
  .ilink { background: none; border: 0; padding: 0; color: var(--amber); text-decoration: underline; cursor: pointer; font: inherit; }

  .two { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; margin-bottom: 12px; }

  /* win cards */
  .wincards { display: grid; grid-template-columns: 1fr 1fr; gap: 14px; margin: 4px 0 12px; }
  .wc { padding: 14px 16px; border: 1px solid var(--edge); border-radius: 3px; background: rgba(8, 19, 17, 0.5); }
  .wc-k { font-family: var(--font-hud); letter-spacing: 0.16em; text-transform: uppercase; font-size: 0.78rem; color: var(--amber); margin-bottom: 8px; }
  .wc p { margin: 0; font-size: 0.85rem; }

  /* systems grid */
  .sys { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
  .scard { padding: 14px 16px; border: 1px solid var(--edge); border-left: 2px solid var(--phosphor-dim); border-radius: 3px; background: rgba(8, 19, 17, 0.5); }
  .scard h3 { margin: 0 0 6px; font-size: 0.9rem; color: var(--phosphor); }
  .scard p { margin: 0; font-size: 0.82rem; line-height: 1.55; }

  /* contract */
  .contract { display: grid; gap: 8px; margin: 4px 0 8px; }
  .cc { display: grid; grid-template-columns: 84px 96px 1fr; align-items: center; gap: 12px; padding: 9px 14px; border: 1px solid var(--edge); border-left: 2px solid var(--phosphor-dim); border-radius: 3px; background: rgba(8, 19, 17, 0.5); }
  .cc-k { font-family: var(--font-hud); letter-spacing: 0.1em; color: var(--phosphor-hot); }
  .cc-v { font-family: var(--font-hud); font-size: 0.78rem; color: var(--amber); }
  .cc-d { font-size: 0.83rem; }

  /* type table */
  .types { display: flex; flex-direction: column; gap: 2px; }
  .trow { display: grid; grid-template-columns: 16px 88px 148px 96px 1fr; align-items: center; gap: 10px; padding: 7px 8px; font-size: 0.81rem; border-bottom: 1px solid rgba(92, 242, 166, 0.06); }
  .sw { width: 11px; height: 11px; transform: rotate(45deg); border: 1px solid rgba(0, 0, 0, 0.5); }
  .tk { font-family: var(--font-hud); color: var(--phosphor-hot); letter-spacing: 0.05em; }
  .te { font-family: var(--font-hud); font-size: 0.7rem; color: var(--muted); }
  .tb { font-size: 0.73rem; color: var(--muted); }
  .tb.on { color: var(--phosphor); }
  .tr { color: var(--ink); }

  /* edit cards */
  .cards { display: grid; grid-template-columns: repeat(2, 1fr); gap: 12px; }
  .card { position: relative; padding: 13px 15px; background: rgba(8, 19, 17, 0.55); border: 1px solid var(--edge); border-radius: 3px; }
  .card h4 { margin: 0 0 6px; font-family: var(--font-hud); font-size: 0.88rem; font-weight: 400; letter-spacing: 0.03em; color: var(--phosphor); }
  .card p { margin: 0; font-size: 0.81rem; line-height: 1.5; }
  .card .c { position: absolute; width: 8px; height: 8px; border: 1px solid var(--phosphor-dim); opacity: 0.6; }
  .card .tl { top: 4px; left: 4px; border-right: 0; border-bottom: 0; }
  .card .tr2 { top: 4px; right: 4px; border-left: 0; border-bottom: 0; }
  .card .bl { bottom: 4px; left: 4px; border-right: 0; border-top: 0; }
  .card .br { bottom: 4px; right: 4px; border-left: 0; border-top: 0; }

  .ticks { margin: 0 0 8px; padding-left: 0; list-style: none; }
  .ticks li { position: relative; padding-left: 20px; margin-bottom: 7px; font-size: 0.85rem; line-height: 1.5; }
  .ticks li::before { content: '▸'; position: absolute; left: 2px; color: var(--amber); }
  .run { margin: 0; padding-left: 20px; }
  .run li { font-size: 0.86rem; line-height: 1.6; margin-bottom: 6px; }

  /* mission taxonomy */
  .missions { display: flex; flex-direction: column; gap: 2px; }
  .mrow { display: grid; grid-template-columns: 172px 90px 1fr; align-items: center; gap: 12px; padding: 8px; font-size: 0.83rem; border-bottom: 1px solid rgba(92, 242, 166, 0.06); }
  .mm { font-family: var(--font-hud); color: var(--phosphor-hot); letter-spacing: 0.04em; }
  .mw { font-family: var(--font-hud); font-size: 0.68rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }
  .mw.fw { color: var(--amber); }
  .mw.rot { color: var(--phosphor); }
  .md { color: var(--ink); }

  /* glossary */
  .glossary { display: grid; grid-template-columns: 1fr 1fr; gap: 2px 24px; }
  .grow { display: grid; grid-template-columns: 128px 1fr; gap: 10px; padding: 6px 0; border-bottom: 1px solid rgba(92, 242, 166, 0.06); align-items: baseline; }
  .gt { font-family: var(--font-hud); color: var(--phosphor-hot); font-size: 0.78rem; }
  .gd { font-size: 0.79rem; color: var(--ink); line-height: 1.45; }

  .foot { padding: 18px 38px 24px; font-size: 0.78rem; line-height: 1.55; color: var(--muted); }

  @media (max-width: 660px) {
    .hero { padding: 24px 20px 18px; }
    .hero h1 { font-size: 1.5rem; }
    .hero h1 .sep { display: block; height: 0; margin: 0; overflow: hidden; }
    .toc, .ch, .foot { padding-left: 20px; padding-right: 20px; }
    .two, .wincards, .sys, .cards, .glossary { grid-template-columns: 1fr; }
    .toc-s { display: none; }
    .cc { grid-template-columns: 74px 1fr; }
    .cc-d { grid-column: 1 / -1; }
    .trow { grid-template-columns: 14px 82px 1fr; }
    .te, .tb { display: none; }
    .mrow { grid-template-columns: 132px 1fr; }
    .mw { display: none; }
    .grow { grid-template-columns: 108px 1fr; }
  }
</style>
