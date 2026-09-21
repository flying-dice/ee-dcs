<script context="module" lang="ts">
  export interface ProjBadge { text: string; tone: 'green' | 'amber' | 'red'; }
  export interface SideSummary { airbases: number; farps: number; total: number; }
</script>
<script lang="ts">
  import { createEventDispatcher } from 'svelte';
  import { KEYSITE_TYPES } from '../lib/types';
  import type { Terrain, KeysiteType, Side, CountConfig, Keysite, AdminBoundary } from '../lib/types';
  import { AIRCRAFT_ROLES, DEFAULT_UNIT_TYPES } from '../lib/units';
  import type { AircraftRole, UnitTypes } from '../lib/units';
  import type { Mode } from './MapView.svelte';

  export let terrains: Terrain[] = [];
  export let selectedTerrainId = '';
  export let terrain: Terrain | null = null;
  export let projBadge: ProjBadge | null = null;
  export let mode: Mode = 'idle';
  export let mainBlueName: string | null = null;
  export let mainRedName: string | null = null;
  export let canPopulate = false;
  export let populated = false;
  export let loadingOsm = false;
  export let osmLoaded = false;
  export let osmError: string | null = null;
  export let mainError: string | null = null;
  export let adminBoundaryCount = 0;
  export let adminBlueRearCount = 0;
  export let adminBlueCloseCount = 0;
  export let adminRedRearCount = 0;
  export let adminRedCloseCount = 0;
  export let hasBlueTerritory = false;
  export let hasRedTerritory = false;
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
  export let assignmentBoundary: AdminBoundary | null = null;
  export let assignmentSide: Side = 'blue';
  export let assignmentRole: 'rear' | 'close' = 'rear';
  const dispatch = createEventDispatcher<{
    selectTerrain: string; setMode: Mode; clearMain: Side; populate: void; shuffle: void;
    setCount: { type: KeysiteType; side: Side; value: number }; applyCounts: void; setUnit: { side: Side; role: AircraftRole; value: string }; resetUnits: void; removeKeysite: string;
    focusKeysite: string; reset: void; generate: void; downloadGeoJson: void; setBakeCampaign: boolean; openManual: void;
    setAssignmentSide: Side; setAssignmentRole: 'rear' | 'close'; applyAssignment: void; clearAssignment: void; cancelAssignment: void;
  }>();
  const SIDES: Side[] = ['blue', 'red'];
  $: grouped = group(keysites);
  function group(items: Keysite[]): Record<Side, Keysite[]> { return { blue: items.filter((item) => item.side === 'blue'), red: items.filter((item) => item.side === 'red') }; }
  function toggle(next: Mode): void { dispatch('setMode', mode === next ? 'idle' : next); }
  function setCount(type: KeysiteType, side: Side, event: Event): void { dispatch('setCount', { type, side, value: Number((event.currentTarget as HTMLInputElement).value) }); }
  function setSide(event: Event): void { dispatch('setAssignmentSide', (event.currentTarget as HTMLSelectElement).value as Side); }
  function setRole(event: Event): void { dispatch('setAssignmentRole', (event.currentTarget as HTMLSelectElement).value as 'rear' | 'close'); }
  function setUnit(side: Side, role: AircraftRole, event: Event): void { dispatch('setUnit', { side, role, value: (event.currentTarget as HTMLInputElement).value }); }
</script>

<aside class="panel island">
  <header><div class="brand"><span class="mark">◣◤</span><div><h1>EE-DCS</h1><span>Campaign Generator</span></div></div></header>
  <p class="hint"><span>&gt;</span> {hint}</p>
  <section>
    <div class="step">1 · Terrain</div>
    <select value={selectedTerrainId} on:change={(event) => dispatch('selectTerrain', event.currentTarget.value)}><option value="" disabled>Pick a DCS theatre…</option>{#each terrains as item (item.id)}<option value={item.id}>{item.label}</option>{/each}</select>
    {#if projBadge}<span class="badge {projBadge.tone}">{projBadge.text}</span>{/if}
    {#if loadingOsm}<span class="muted">Loading DCS + OSM exports…</span>{:else if osmLoaded}<span class="badge green">DCS + OSM exports loaded ✓</span>{:else if osmError}<span class="error">{osmError}</span>{/if}
  </section>
  <section class:disabled={!terrain || !osmLoaded}>
    <div class="step">2 · Initial distribution</div>
    <span class="muted">Click a boundary to assign its side and operational role.</span>
    <div class="territory-counts"><span>BLU rear {adminBlueRearCount} · close {adminBlueCloseCount}</span><span>RED rear {adminRedRearCount} · close {adminRedCloseCount}</span></div>
    <span class="muted">{adminBoundaryCount} administrative boundaries loaded</span>
  </section>
  <section class:disabled={!terrain || !osmLoaded}>
    <div class="step">3 · Main airbases</div>
    <span class="muted">Choose an airbase inside an assigned territory for each side.</span>
    <div class="row"><button class:active={mode === 'main-blue'} disabled={!hasBlueTerritory} on:click={() => toggle('main-blue')}>BLUE main</button><button class:active={mode === 'main-red'} disabled={!hasRedTerritory} on:click={() => toggle('main-red')}>RED main</button></div>
    {#if mainError}<div class="error">{mainError}</div>{/if}
    <div class="mains">{#if mainBlueName}<span class="blue">{mainBlueName}<button on:click={() => dispatch('clearMain', 'blue')}>×</button></span>{/if}{#if mainRedName}<span class="red">{mainRedName}<button on:click={() => dispatch('clearMain', 'red')}>×</button></span>{/if}</div>
  </section>
  <section class:disabled={!canPopulate && !populated}>
    <div class="step">4 · Keysites</div>
    <button class="primary" disabled={!canPopulate} on:click={() => dispatch('populate')}>{populated ? 'Rebuild keysites' : 'Populate keysites'}</button>
    {#if canPopulate || populated}<div class="counts"><div class="head"><span>type</span><span>BLU</span><span>RED</span></div>{#each KEYSITE_TYPES as type}<div class="count"><span><i style="background:{typeColors[type]}"></i>{type}</span><input type="number" min="0" max="20" value={counts[type].blue} on:input={(event) => setCount(type, 'blue', event)} /><input type="number" min="0" max="20" value={counts[type].red} on:input={(event) => setCount(type, 'red', event)} /></div>{/each}</div>{#if populated}<button class="primary" disabled={!countsDirty} on:click={() => dispatch('applyCounts')}>{countsDirty ? 'Apply counts' : 'Counts applied'}</button><div class="row"><button on:click={() => dispatch('shuffle')}>Shuffle</button><button class:active={mode === 'edit'} on:click={() => toggle('edit')}>{mode === 'edit' ? 'Editing…' : 'Edit on map'}</button></div>{/if}{/if}
    {#if populated}<div class="list">{#each SIDES as side}<div><b class={side}>{side.toUpperCase()} · {grouped[side].length}</b>{#each grouped[side] as keysite (keysite.id)}<div class="site" role="button" tabindex="0" on:click={() => dispatch('focusKeysite', keysite.id)} on:keydown={(event) => (event.key === 'Enter' || event.key === ' ') && dispatch('focusKeysite', keysite.id)}><i style="background:{typeColors[keysite.type]}"></i><span>{keysite.type} · {keysite.name}</span><button on:click|stopPropagation={() => dispatch('removeKeysite', keysite.id)}>×</button></div>{/each}</div>{/each}</div>{/if}
  </section>
  {#if populated}<section><div class="step">5 · Balance</div><div class="territory-counts"><span class="blue">BLU {blueSummary.airbases} ab · {blueSummary.farps} farp · {blueSummary.total} total</span><span class="red">RED {redSummary.airbases} ab · {redSummary.farps} farp · {redSummary.total} total</span></div></section>{/if}
  <section>
    <div class="step">6 · Generate</div>
    <label class="bake"><input type="checkbox" checked={bakeCampaign} on:change={(event) => dispatch('setBakeCampaign', event.currentTarget.checked)} /><span>Ship campaign Lua in the <code>.miz</code></span></label>
    <span class="muted">{bakeCampaign ? 'Bundles the EECH campaign so the mission plays as-is.' : 'Exports zones only for a custom mission-init script.'}</span>
    {#if bakeCampaign}<details class="units"><summary>Aircraft types</summary><div class="units-grid"><div class="urow uhead"><span></span><span class="blue">BLU</span><span class="red">RED</span></div>{#each AIRCRAFT_ROLES as role}<div class="urow"><span>{role.label}</span><input value={unitTypes.blue[role.key]} on:input={(event) => setUnit('blue', role.key, event)} spellcheck="false" /><input value={unitTypes.red[role.key]} on:input={(event) => setUnit('red', role.key, event)} spellcheck="false" /></div>{/each}</div><div class="unit-actions"><span class="muted">Exact DCS aircraft type names.</span><button on:click={() => dispatch('resetUnits')}>Reset</button></div></details>{/if}
    <button class="primary" disabled={!canGenerate} on:click={() => dispatch('generate')}>{generating ? 'Building…' : 'Generate .miz'}</button>{#if generateResult}<span class="ok">{generateResult}</span>{/if}<button disabled={keysites.length === 0} on:click={() => dispatch('downloadGeoJson')}>Download zones (GeoJSON)</button>
  </section>
  <section><button on:click={() => dispatch('reset')}>Reset distribution</button></section>
  <footer><button class="manual" on:click={() => dispatch('openManual')}>▣ Operations Manual — how to play &amp; edit</button><p>Assign administrative regions to BLU or RED as rear or close territory, select each side’s main airbase, then generate and tune the keysite network.</p></footer>
</aside>

{#if assignmentBoundary}
  <div class="modal-backdrop" role="presentation"></div>
  <section class="assignment-modal" role="dialog" aria-modal="true" aria-labelledby="assignment-title">
    <h2 id="assignment-title">{assignmentBoundary.name || assignmentBoundary.id}</h2><p>Assign this administrative territory.</p>
    <label>Side<select value={assignmentSide} on:change={setSide}><option value="blue">BLU</option><option value="red">RED</option></select></label>
    <label>Role<select value={assignmentRole} on:change={setRole}><option value="rear">Rear</option><option value="close">Close</option></select></label>
    <div class="row"><button class="primary" on:click={() => dispatch('applyAssignment')}>Apply</button><button on:click={() => dispatch('clearAssignment')}>Clear assignment</button><button on:click={() => dispatch('cancelAssignment')}>Cancel</button></div>
  </section>
{/if}

<style>
  .panel { width:330px; max-height:100%; overflow:auto; padding:0; background:var(--panel); color:var(--ink); } header,section { display:flex; flex-wrap:wrap; gap:7px; padding:11px 14px; border-bottom:1px solid var(--edge); } .brand{display:flex;align-items:center;gap:10px}.mark{color:var(--phosphor);font:1.15rem var(--font-hud);letter-spacing:-.15em;text-shadow:var(--glow)} h1,.step { width:100%; margin:0; font:.76rem var(--font-hud); letter-spacing:.13em; color:var(--phosphor); } header h1{font-size:.98rem;color:var(--phosphor-hot)} header span,.muted { font-size:.73rem; color:var(--muted); } .hint{margin:0;padding:8px 14px;background:rgba(246,166,35,.06);border-bottom:1px solid var(--edge);font-size:.76rem;line-height:1.4}.hint span{color:var(--amber);margin-right:4px} select,input { background:var(--panel-2); border:1px solid var(--edge); color:var(--ink); padding:5px; } select { width:100%; } button { background:var(--panel-2); color:var(--ink); border:1px solid var(--edge); padding:6px 8px; cursor:pointer; } button.primary,button.active { color:var(--phosphor-hot); border-color:var(--edge-hot); background:var(--accent-dim); } button:disabled { opacity:.45; cursor:default; } .disabled { opacity:.48; pointer-events:none; } .row,.territory-counts,.mains,.list { display:flex; gap:6px; width:100%; flex-wrap:wrap; } .row button { flex:1; } .territory-counts span,.mains span { padding:4px 6px; border:1px solid var(--edge); font-size:.7rem; } .blue { color:var(--friendly); } .red { color:var(--hostile); } .counts { width:100%; } .head,.count { display:grid; grid-template-columns:1fr 44px 44px; gap:5px; align-items:center; font-size:.72rem; margin:3px 0; } .count i,.site i { display:inline-block; width:8px; height:8px; transform:rotate(45deg); margin-right:5px; } .list > div { flex:1; min-width:0; } .site { display:flex; align-items:center; gap:4px; font-size:.68rem; cursor:pointer; padding:3px; } .site span { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; flex:1; } .site button,.mains button { padding:0 4px; } .error { color:#ffd6d8; border:1px solid var(--hostile); padding:6px; font-size:.72rem; } .ok { color:var(--phosphor-hot); font-size:.72rem; } .badge { font-size:.68rem; padding:3px 6px; border:1px solid var(--edge); } .badge.green { color:var(--phosphor-hot); } .bake{display:flex;align-items:center;gap:7px;width:100%;font-size:.76rem}.bake input{width:auto;accent-color:var(--phosphor)}.units{width:100%}.units summary{cursor:pointer;color:var(--phosphor-dim);font:.7rem var(--font-hud);letter-spacing:.1em;text-transform:uppercase}.units-grid{display:flex;flex-direction:column;gap:3px;margin:7px 0}.urow{display:grid;grid-template-columns:1fr 92px 92px;gap:5px;align-items:center;font-size:.68rem}.urow input{min-width:0;width:100%;box-sizing:border-box;font-size:.68rem}.uhead{text-align:center;font: .62rem var(--font-hud)}.unit-actions{display:flex;gap:6px;align-items:center}.unit-actions .muted{flex:1}.manual{width:100%;color:var(--phosphor-hot);border-color:var(--edge-hot);background:var(--accent-dim)}footer{padding:11px 14px;color:var(--muted);font-size:.7rem;line-height:1.4}footer p{margin:8px 0 0}.modal-backdrop { position:fixed; inset:0; pointer-events:auto; background:rgba(3,8,7,.28); backdrop-filter:blur(1px); z-index:1000; } .assignment-modal { position:fixed; z-index:1001; pointer-events:auto; left:50%; top:50%; transform:translate(-50%,-50%); width:min(340px,calc(100vw - 32px)); display:flex; flex-wrap:wrap; gap:10px; background:var(--panel); border:1px solid var(--edge-hot); box-shadow:0 15px 50px #000; } .assignment-modal h2,.assignment-modal p,.assignment-modal label { width:100%; margin:0; } .assignment-modal h2 { font:.85rem var(--font-hud); color:var(--phosphor-hot); } .assignment-modal p { color:var(--muted); font-size:.75rem; } .assignment-modal label { font-size:.75rem; } .assignment-modal select { margin-top:4px; }
  @media(max-width:720px){.panel{width:100%;max-height:100vh}.urow{grid-template-columns:1fr 88px 88px}button,select,input{min-height:36px}}
</style>
