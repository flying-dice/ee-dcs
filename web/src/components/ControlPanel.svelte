<script context="module" lang="ts">
  export interface ProjBadge {
    text: string;
    tone: 'green' | 'amber' | 'red';
  }
  export interface SideSummary {
    airbases: number;
    farps: number;
    total: number;
  }
</script>

<script lang="ts">
  // ── ControlPanel: the numbered designer workflow on the left ───────────────────
  // Pure presentation + event dispatch — App.svelte owns all state. Flow:
  //   terrain → bbox → frontline → main airbases (click rings) → populate keysites
  //   (per-type counts, shuffle, edit add/remove) → generate.
  import { createEventDispatcher } from 'svelte';
  import { KEYSITE_TYPES } from '../lib/types';
  import type { Terrain, KeysiteType, Side, CountConfig, Keysite } from '../lib/types';
  import { AIRCRAFT_ROLES, DEFAULT_UNIT_TYPES } from '../lib/units';
  import type { UnitTypes, AircraftRole } from '../lib/units';
  import type { Mode } from './MapView.svelte';

  export let terrains: Terrain[] = [];
  export let selectedTerrainId = '';
  export let terrain: Terrain | null = null;
  export let projBadge: ProjBadge | null = null;
  export let mode: Mode = 'idle';
  export let hasBbox = false;
  export let bboxValid = false;
  export let frontlineCount = 0;
  export let frontlineComplete = false;
  export let mainBlueName: string | null = null;
  export let mainRedName: string | null = null;
  export let canPopulate = false;
  export let populated = false;
  export let loadingOsm = false;
  export let osmError: string | null = null;
  export let counts: CountConfig;
  export let countsDirty = false;
  export let keysites: Keysite[] = [];
  export let blueSummary: SideSummary = { airbases: 0, farps: 0, total: 0 };
  export let redSummary: SideSummary = { airbases: 0, farps: 0, total: 0 };
  export let canGenerate = false;
  export let generating = false;
  export let generateResult: string | null = null;
  export let bakeCampaign = true;
  export let unitTypes: UnitTypes = DEFAULT_UNIT_TYPES;
  export let hint = '';
  export let typeColors: Record<KeysiteType, string> = {} as Record<KeysiteType, string>;

  const dispatch = createEventDispatcher<{
    selectTerrain: string;
    setMode: Mode;
    confirmBbox: void;
    finishFrontline: void;
    clearFrontline: void;
    confirmFrontline: void;
    clearMain: Side;
    populate: void;
    shuffle: void;
    setCount: { type: KeysiteType; side: Side; value: number };
    applyCounts: void;
    setUnit: { side: Side; role: AircraftRole; value: string };
    resetUnits: void;
    removeKeysite: string;
    reset: void;
    generate: void;
    downloadGeoJson: void;
    setBakeCampaign: boolean;
    focusKeysite: string;
    openManual: void;
  }>();

  $: stepFront = hasBbox && bboxValid;
  $: hasBothMains = !!mainBlueName && !!mainRedName;
  $: blueEmpty = blueSummary.total === 0 || blueSummary.airbases < 1;
  $: redEmpty = redSummary.total === 0 || redSummary.airbases < 1;

  // Keysites grouped for the editable list: side → type → items.
  $: grouped = groupKeysites(keysites);
  function groupKeysites(ks: Keysite[]): Record<Side, Keysite[]> {
    const g: Record<Side, Keysite[]> = { blue: [], red: [] };
    for (const k of ks) g[k.side].push(k);
    const order = (a: Keysite, b: Keysite) =>
      KEYSITE_TYPES.indexOf(a.type) - KEYSITE_TYPES.indexOf(b.type) || a.name.localeCompare(b.name);
    g.blue.sort(order);
    g.red.sort(order);
    return g;
  }

  const SIDES: Side[] = ['blue', 'red'];

  function toggle(m: Mode): void {
    dispatch('setMode', mode === m ? 'idle' : m);
  }
  function onCount(type: KeysiteType, side: Side, e: Event): void {
    const value = Number((e.currentTarget as HTMLInputElement).value);
    dispatch('setCount', { type, side, value });
  }
  function onUnit(side: Side, role: AircraftRole, e: Event): void {
    dispatch('setUnit', { side, role, value: (e.currentTarget as HTMLInputElement).value });
  }
</script>

<aside class="panel island">
  <header>
    <div class="brand">
      <span class="mark">◣◤</span>
      <div>
        <h1>EE-DCS</h1>
        <div class="sub">Campaign Generator</div>
      </div>
    </div>
  </header>

  <p class="hint"><span class="caret">&gt;</span> {hint}</p>

  <!-- 1. terrain -->
  <section>
    <div class="step">1 · Terrain</div>
    <select value={selectedTerrainId} on:change={(e) => dispatch('selectTerrain', e.currentTarget.value)}>
      <option value="" disabled>Pick a DCS theatre…</option>
      {#each terrains as t (t.id)}
        <option value={t.id}>{t.label}</option>
      {/each}
    </select>
    {#if projBadge}
      <span class="badge {projBadge.tone}">{projBadge.text}</span>
    {/if}
  </section>

  <!-- 2. bbox -->
  <section class:disabled={!terrain}>
    <div class="step">2 · Theatre area</div>
    <div class="row">
      <button class:active={mode === 'bbox'} disabled={!terrain} on:click={() => toggle('bbox')}>
        {hasBbox ? 'Redraw' : 'Draw bbox'}
      </button>
      {#if hasBbox}
        <button class:active={mode === 'bbox-edit'} on:click={() => dispatch('setMode', 'bbox-edit')}>
          Move / resize
        </button>
      {/if}
    </div>
    {#if mode === 'bbox-edit'}
      <button class="primary" on:click={() => dispatch('confirmBbox')}>✓ Done — lock the area</button>
    {/if}
    {#if hasBbox}
      {#if bboxValid}<span class="badge green">inside terrain ✓</span>
      {:else}<span class="badge red">outside terrain — redraw</span>{/if}
    {/if}
  </section>

  <!-- 3. frontline -->
  <section class:disabled={!stepFront}>
    <div class="step">3 · Frontline</div>
    <div class="row">
      <button class:active={mode === 'frontline'} disabled={!stepFront} on:click={() => toggle('frontline')}>
        {frontlineCount > 0 ? 'Redraw' : 'Draw'} frontline
      </button>
      <button disabled={mode !== 'frontline' || frontlineCount < 2} on:click={() => dispatch('finishFrontline')}>
        Finish
      </button>
      <button disabled={frontlineCount === 0} on:click={() => dispatch('clearFrontline')}>Clear</button>
    </div>
    {#if frontlineCount >= 2}
      <div class="row">
        <button class:active={mode === 'frontline-edit'} on:click={() => dispatch('setMode', 'frontline-edit')}>
          Edit vertices
        </button>
        {#if mode === 'frontline-edit'}
          <button class="primary" on:click={() => dispatch('confirmFrontline')}>✓ Done</button>
        {/if}
      </div>
    {/if}
    <span class="muted">
      {frontlineCount} vertices{frontlineComplete ? ' · complete' : frontlineCount > 0 ? ' · drawing' : ''}
    </span>
  </section>

  <!-- 4. main airbases (click DCS rings) -->
  <section class:disabled={!stepFront}>
    <div class="step">4 · Main airbases</div>
    <span class="muted">Click a DCS airbase ring on the map to set each side's main.</span>
    <div class="row">
      <button class="side-blue" class:active={mode === 'main-blue'} disabled={!stepFront} on:click={() => toggle('main-blue')}>
        {mainBlueName ? '✓ ' : ''}BLUE main
      </button>
      <button class="side-red" class:active={mode === 'main-red'} disabled={!stepFront} on:click={() => toggle('main-red')}>
        {mainRedName ? '✓ ' : ''}RED main
      </button>
    </div>
    {#if mainBlueName || mainRedName}
      <div class="mains">
        {#if mainBlueName}
          <span class="mn blue">{mainBlueName}<button class="x" title="clear" on:click={() => dispatch('clearMain', 'blue')}>×</button></span>
        {/if}
        {#if mainRedName}
          <span class="mn red">{mainRedName}<button class="x" title="clear" on:click={() => dispatch('clearMain', 'red')}>×</button></span>
        {/if}
      </div>
    {/if}
  </section>

  <!-- 5. keysites -->
  <section class:disabled={!canPopulate && !populated}>
    <div class="step">5 · Keysites</div>
    <button class="primary" disabled={!canPopulate || loadingOsm} on:click={() => dispatch('populate')}>
      {#if loadingOsm}<span class="spinner"></span> Loading open data…
      {:else}{populated ? 'Re-populate from OSM' : 'Populate keysites'}{/if}
    </button>
    {#if osmError}<div class="toast error">{osmError}</div>{/if}

    {#if canPopulate || populated}
      <div class="counts">
        <div class="chead"><span>type</span><span class="cn">BLU</span><span class="cn">RED</span></div>
        {#each KEYSITE_TYPES as t}
          <div class="crow">
            <span class="ctype"><i style="background:{typeColors[t]}"></i>{t}</span>
            <input class="cn" type="number" min="0" max="20" value={counts[t].blue} on:input={(e) => onCount(t, 'blue', e)} />
            <input class="cn" type="number" min="0" max="20" value={counts[t].red} on:input={(e) => onCount(t, 'red', e)} />
          </div>
        {/each}
      </div>
      {#if populated}
        <button class="primary apply" disabled={!countsDirty} on:click={() => dispatch('applyCounts')}>
          {countsDirty ? '✓ Apply counts — rebuild' : 'Counts applied'}
        </button>
        <span class="muted">Edit the numbers freely — nothing rebuilds until you Apply.</span>
      {:else}
        <span class="muted">Set counts here; Populate builds with them.</span>
      {/if}
    {/if}

    {#if populated}
      <div class="row">
        <button class="primary" on:click={() => dispatch('shuffle')}>⟳ Shuffle</button>
        <button class:active={mode === 'edit'} on:click={() => toggle('edit')}>
          {mode === 'edit' ? 'Editing…' : 'Edit on map'}
        </button>
      </div>
      <span class="muted">{keysites.length} zones · shuffle re-rolls, edit adds/removes on the map</span>

      <!-- selected list, grouped by side -->
      <div class="list">
        {#each SIDES as side (side)}
          <div class="lgroup {side}">
            <div class="lhead">{side.toUpperCase()} · {grouped[side].length}</div>
            {#each grouped[side] as k (k.id)}
              <div
                class="litem"
                role="button"
                tabindex="0"
                title="Click to locate on the map"
                on:click={() => dispatch('focusKeysite', k.id)}
                on:keydown={(e) => (e.key === 'Enter' || e.key === ' ') && dispatch('focusKeysite', k.id)}
              >
                <i class="dot" style="background:{typeColors[k.type]}"></i>
                <span class="lty">{k.type}{k.isMain ? ' ★' : ''}</span>
                <span class="lnm" title={k.name}>{k.name}</span>
                <button
                  class="x"
                  title="remove"
                  on:click|stopPropagation={() => dispatch('removeKeysite', k.id)}
                >×</button>
              </div>
            {/each}
            {#if grouped[side].length === 0}<div class="lempty">no sites</div>{/if}
          </div>
        {/each}
      </div>
    {/if}
  </section>

  <!-- 6. preview summary -->
  {#if populated}
    <section>
      <div class="step">6 · Balance</div>
      <div class="summary">
        <div class="side blue">
          <b>BLUE</b>
          <span>{blueSummary.airbases} ab · {blueSummary.farps} farp · {blueSummary.total} total</span>
          {#if blueEmpty}<span class="warn">⚠ needs ≥ 1 airbase</span>{/if}
        </div>
        <div class="side red">
          <b>RED</b>
          <span>{redSummary.airbases} ab · {redSummary.farps} farp · {redSummary.total} total</span>
          {#if redEmpty}<span class="warn">⚠ needs ≥ 1 airbase</span>{/if}
        </div>
      </div>
    </section>
  {/if}

  <!-- 7. generate -->
  <section>
    <div class="step">7 · Generate</div>
    <label class="bake">
      <input type="checkbox" checked={bakeCampaign} on:change={(e) => dispatch('setBakeCampaign', e.currentTarget.checked)} />
      <span>Ship campaign Lua in the <code>.miz</code></span>
    </label>
    <span class="muted bake-note">
      {#if bakeCampaign}Bundles the EECH campaign — the <code>.miz</code> plays as-is (~1&nbsp;MB).
      {:else}Zones only — you add a mission-init script yourself.{/if}
    </span>

    {#if bakeCampaign}
      <details class="units">
        <summary>Aircraft types</summary>
        <div class="units-grid">
          <div class="uhead"><span></span><span class="uc fr">BLUE</span><span class="uc ho">RED</span></div>
          {#each AIRCRAFT_ROLES as r}
            <div class="urow">
              <span class="ur">{r.label}</span>
              <input class="uin" value={unitTypes.blue[r.key]} on:input={(e) => onUnit('blue', r.key, e)} spellcheck="false" />
              <input class="uin" value={unitTypes.red[r.key]} on:input={(e) => onUnit('red', r.key, e)} spellcheck="false" />
            </div>
          {/each}
        </div>
        <div class="uactions">
          <span class="muted">Exact DCS type names — these override the campaign’s defaults in the shipped Lua.</span>
          <button class="tiny" on:click={() => dispatch('resetUnits')}>reset</button>
        </div>
      </details>
    {/if}

    <button class="primary" disabled={!canGenerate} on:click={() => dispatch('generate')}>
      {#if generating}<span class="spinner"></span> Building…{:else}Generate .miz{/if}
    </button>
    {#if generateResult}<div class="toast ok">{generateResult}</div>{/if}
    <button class="tiny" disabled={keysites.length === 0} on:click={() => dispatch('downloadGeoJson')}>
      Download frontline + zones (GeoJSON)
    </button>
  </section>

  <section>
    <button on:click={() => dispatch('reset')}>Reset design (keep terrain + bbox)</button>
  </section>

  <footer>
    <button class="manual-btn" on:click={() => dispatch('openManual')}>
      <span class="mi">▣</span> Operations Manual — how to play &amp; edit
    </button>
    <details>
      <summary>How this works</summary>
      <p>
        Draw the <b>theatre bbox</b> and a <b>frontline</b>, then click DCS <b>airbase
        rings</b> to set each side's main. <b>Populate</b> pulls FARPs + support sites from
        OpenStreetMap and builds a balanced network — real DCS airfields for airbases, open
        data for the rest. Tune per-type <b>counts</b>, <b>Shuffle</b> to re-roll placements,
        or <b>Edit on map</b> to add/remove individual sites. The result is written as trigger
        zones (colour = side, first word of the name = type) and, by default, the EECH
        campaign Lua is baked in so the <code>.miz</code> plays as-is.
      </p>
      <p class="attr">
        Map data © <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>
        contributors, via the <a href="https://overpass-api.de/" target="_blank" rel="noopener">Overpass API</a>.
      </p>
    </details>
  </footer>
</aside>

<style>
  .panel {
    align-self: flex-start;
    max-height: 100%;
    width: 318px;
    overflow-y: auto;
    padding: 0;
    display: flex;
    flex-direction: column;
  }

  header {
    padding: 12px 14px 11px;
    border-bottom: 1px solid var(--edge);
  }
  .brand { display: flex; align-items: center; gap: 9px; }
  .brand .mark {
    font-family: var(--font-hud);
    font-size: 1.15rem;
    color: var(--phosphor);
    text-shadow: var(--glow);
    letter-spacing: -0.15em;
  }
  header h1 {
    margin: 0;
    font-family: var(--font-hud);
    font-size: 0.98rem;
    font-weight: 400;
    letter-spacing: 0.16em;
    color: var(--phosphor-hot);
    text-shadow: var(--glow);
  }
  .brand .sub {
    font-size: 0.68rem;
    letter-spacing: 0.22em;
    text-transform: uppercase;
    color: var(--amber);
  }
  code { padding: 0 3px; font-size: 0.9em; }

  .hint {
    margin: 0;
    padding: 8px 14px;
    font-size: 0.76rem;
    background: rgba(246, 166, 35, 0.06);
    border-bottom: 1px solid var(--edge);
    color: var(--ink);
    line-height: 1.4;
  }
  .hint .caret { color: var(--amber); font-family: var(--font-hud); margin-right: 4px; }

  section {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 6px;
    padding: 11px 14px;
    border-bottom: 1px solid var(--edge);
  }
  section.disabled { opacity: 0.42; pointer-events: none; }
  .step {
    width: 100%;
    font-family: var(--font-hud);
    font-size: 0.72rem;
    letter-spacing: 0.16em;
    text-transform: uppercase;
    color: var(--phosphor-dim);
    display: flex;
    align-items: center;
    gap: 7px;
  }
  .step::before {
    content: '';
    width: 6px;
    height: 6px;
    background: var(--phosphor-dim);
    box-shadow: 0 0 4px currentColor;
    transform: rotate(45deg);
    flex: none;
  }
  select { flex: 1 1 100%; }
  .row { display: flex; gap: 6px; flex-wrap: wrap; width: 100%; }
  .row button { flex: 1 1 auto; }

  button.active {
    border-color: var(--phosphor);
    background: var(--accent-dim);
    color: var(--phosphor-hot);
    box-shadow: inset 0 0 10px rgba(92, 242, 166, 0.18), var(--glow);
  }
  button.side-blue.active {
    border-color: var(--friendly);
    background: var(--friendly-dim);
    color: #cfe8ff;
    box-shadow: 0 0 6px rgba(74, 168, 255, 0.4);
  }
  button.side-red.active {
    border-color: var(--hostile);
    background: var(--hostile-dim);
    color: #ffd6d8;
    box-shadow: 0 0 6px rgba(255, 81, 87, 0.4);
  }
  button.tiny { font-size: 0.72rem; padding: 4px 8px; flex: 0 0 auto; }

  .badge {
    font-family: var(--font-hud);
    font-size: 0.68rem;
    letter-spacing: 0.08em;
    padding: 2px 7px;
    border-radius: 2px;
    border: 1px solid var(--edge);
    white-space: nowrap;
  }
  .badge.green { color: var(--phosphor-hot); border-color: var(--edge-hot); background: var(--accent-dim); text-shadow: var(--glow); }
  .badge.amber { color: var(--amber); border-color: #7a5410; background: var(--amber-dim); }
  .badge.red { color: #ffd6d8; border-color: var(--hostile); background: var(--hostile-dim); }
  .muted { font-size: 0.73rem; color: var(--muted); width: 100%; }

  /* main-airbase chips */
  .mains { display: flex; flex-wrap: wrap; gap: 6px; width: 100%; }
  .mn {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 0.72rem;
    padding: 2px 4px 2px 8px;
    border-radius: 2px;
    border: 1px solid var(--edge);
  }
  .mn.blue { border-left: 2px solid var(--friendly); color: #cfe8ff; }
  .mn.red { border-left: 2px solid var(--hostile); color: #ffd6d8; }

  /* per-type counts grid */
  .counts { width: 100%; display: flex; flex-direction: column; gap: 2px; margin-top: 2px; }
  .chead, .crow {
    display: grid;
    grid-template-columns: 1fr 46px 46px;
    align-items: center;
    gap: 6px;
  }
  .chead {
    font-family: var(--font-hud);
    font-size: 0.62rem;
    letter-spacing: 0.1em;
    text-transform: uppercase;
    color: var(--phosphor-dim);
    padding-bottom: 2px;
  }
  .chead .cn { text-align: center; }
  .chead .cn:nth-of-type(1) { color: var(--friendly); }
  .ctype { display: inline-flex; align-items: center; gap: 6px; font-size: 0.73rem; }
  .ctype i { width: 8px; height: 8px; transform: rotate(45deg); border: 1px solid rgba(0,0,0,0.6); flex: none; }
  input.cn {
    width: 46px;
    padding: 3px 4px;
    text-align: center;
    font-size: 0.75rem;
  }

  .spinner {
    display: inline-block;
    width: 11px;
    height: 11px;
    border: 2px solid currentColor;
    border-top-color: transparent;
    border-radius: 50%;
    animation: spin 0.7s linear infinite;
    vertical-align: -1px;
  }
  @keyframes spin { to { transform: rotate(360deg); } }

  .toast { width: 100%; font-size: 0.75rem; padding: 7px 9px; border-radius: 2px; line-height: 1.35; }
  .toast.error { background: var(--hostile-dim); border: 1px solid var(--hostile); color: #ffd6d8; }
  .toast.ok { background: var(--accent-dim); border: 1px solid var(--edge-hot); color: var(--phosphor-hot); }

  /* selected keysite list */
  .list { width: 100%; display: flex; gap: 8px; margin-top: 2px; }
  .lgroup { flex: 1; min-width: 0; border: 1px solid var(--edge); border-radius: 2px; background: var(--panel-2); overflow: hidden; }
  .lgroup.blue { border-left: 2px solid var(--friendly); }
  .lgroup.red { border-left: 2px solid var(--hostile); }
  .lhead {
    font-family: var(--font-hud);
    font-size: 0.64rem;
    letter-spacing: 0.12em;
    padding: 4px 6px;
    border-bottom: 1px solid var(--edge);
    color: var(--phosphor-dim);
  }
  .lgroup.blue .lhead { color: var(--friendly); }
  .lgroup.red .lhead { color: var(--hostile); }
  .litem { display: flex; align-items: center; gap: 5px; padding: 3px 5px; font-size: 0.7rem; cursor: pointer; }
  .litem:hover { background: var(--accent-dim); }
  .litem:focus-visible { outline: 1px solid var(--phosphor); outline-offset: -1px; }
  .litem .dot { width: 7px; height: 7px; transform: rotate(45deg); flex: none; border: 1px solid rgba(0,0,0,0.5); }
  .lty { color: var(--muted); flex: none; }
  .lnm { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--ink); }
  .lempty { padding: 4px 6px; font-size: 0.68rem; color: var(--muted); }
  button.x {
    flex: none;
    width: 16px;
    height: 16px;
    padding: 0;
    line-height: 1;
    font-size: 0.9rem;
    border: 1px solid var(--edge);
    background: transparent;
    color: var(--muted);
  }
  button.x:hover { color: var(--hostile); border-color: var(--hostile); }

  .summary { display: flex; gap: 8px; width: 100%; }
  .side {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 3px;
    font-size: 0.72rem;
    padding: 7px 9px;
    border-radius: 2px;
    border: 1px solid var(--edge);
    background: var(--panel-2);
  }
  .side b { font-family: var(--font-hud); letter-spacing: 0.14em; font-weight: 400; }
  .side.blue { border-left: 2px solid var(--friendly); }
  .side.blue b { color: var(--friendly); }
  .side.red { border-left: 2px solid var(--hostile); }
  .side.red b { color: var(--hostile); }
  .side .warn { color: var(--amber); }

  .bake { display: flex; align-items: center; gap: 7px; width: 100%; font-size: 0.78rem; color: var(--ink); cursor: pointer; user-select: none; }
  .bake input { width: auto; margin: 0; accent-color: var(--phosphor); cursor: pointer; }
  .bake-note { margin-top: -2px; }

  /* aircraft-type editor */
  .units { width: 100%; }
  .units > summary {
    cursor: pointer;
    font-family: var(--font-hud);
    font-size: 0.72rem;
    letter-spacing: 0.12em;
    text-transform: uppercase;
    color: var(--phosphor-dim);
    padding: 4px 0;
  }
  .units > summary:hover { color: var(--phosphor); }
  .units-grid { display: flex; flex-direction: column; gap: 3px; margin: 6px 0; }
  .uhead, .urow { display: grid; grid-template-columns: 1fr 1fr 1fr; align-items: center; gap: 6px; }
  .uhead { font-family: var(--font-hud); font-size: 0.62rem; letter-spacing: 0.1em; padding-bottom: 2px; }
  .uc { text-align: center; }
  .uc.fr { color: var(--friendly); }
  .uc.ho { color: var(--hostile); }
  .ur { font-size: 0.72rem; color: var(--ink); }
  input.uin {
    width: 100%;
    min-width: 0;
    padding: 3px 5px;
    font-family: var(--font-hud);
    font-size: 0.7rem;
  }
  .uactions { display: flex; align-items: center; gap: 8px; }
  .uactions .muted { flex: 1; }

  footer { padding: 11px 14px 14px; font-size: 0.73rem; color: var(--muted); line-height: 1.45; }
  .manual-btn {
    width: 100%;
    margin-bottom: 10px;
    padding: 9px 10px;
    font-family: var(--font-hud);
    font-size: 0.76rem;
    letter-spacing: 0.08em;
    color: var(--phosphor-hot);
    background: var(--accent-dim);
    border: 1px solid var(--edge-hot);
    text-shadow: var(--glow);
  }
  .manual-btn:hover { background: rgba(92, 242, 166, 0.14); border-color: var(--phosphor); }
  .manual-btn .mi { color: var(--amber); margin-right: 5px; }
  footer summary {
    cursor: pointer;
    color: var(--phosphor-dim);
    font-family: var(--font-hud);
    letter-spacing: 0.1em;
    text-transform: uppercase;
    font-size: 0.7rem;
  }
  .attr { margin-top: 6px; font-size: 0.68rem; }

  /* ── mobile: fill the drawer, roomier tap targets ────────────────────────── */
  @media (max-width: 720px) {
    .panel { width: 100%; }
    header { padding-right: 54px; } /* clear the drawer's close ✕ (nudged off the scrollbar) */
    .panel button:not(.tiny):not(.x) { min-height: 42px; }
    select { min-height: 42px; }
    input.uin { min-height: 36px; }
    input.cn { min-height: 34px; }
    section { padding: 13px 14px; }
  }
</style>
