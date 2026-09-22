<script context="module" lang="ts">
  export interface ProjBadge { text: string; tone: 'green' | 'amber' | 'red'; }
  export interface SideSummary { airbases: number; farps: number; total: number; }
</script>
<script lang="ts">
  import { createEventDispatcher } from 'svelte';
  import { KEYSITE_TYPES } from '../lib/types';
  import type { Terrain, KeysiteType, Side, CountConfig, Keysite } from '../lib/types';
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
  export let designError: string | null = null;
  export let designResult: string | null = null;
  export let mainError: string | null = null;
  export let blueRearCount = 0;
  export let blueCloseCount = 0;
  export let redRearCount = 0;
  export let redCloseCount = 0;
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
  export let paintErase = false;
  export let assignmentSide: Side = 'blue';
  export let assignmentRole: 'rear' | 'close' = 'rear';
  const dispatch = createEventDispatcher<{
    selectTerrain: string; setMode: Mode; clearMain: Side; populate: void; shuffle: void;
    setCount: { type: KeysiteType; side: Side; value: number }; applyCounts: void; setUnit: { side: Side; role: AircraftRole; value: string }; resetUnits: void; removeKeysite: string;
    focusKeysite: string; reset: void; generate: void; exportDesign: void; importDesign: File; setBakeCampaign: boolean; openManual: void;
    setAssignmentSide: Side; setAssignmentRole: 'rear' | 'close'; setPaintErase: boolean;
  }>();
  const SIDES: Side[] = ['blue', 'red'];
  let importInput: HTMLInputElement;
  $: grouped = group(keysites);
  function group(items: Keysite[]): Record<Side, Keysite[]> { return { blue: items.filter((item) => item.side === 'blue'), red: items.filter((item) => item.side === 'red') }; }
  function toggle(next: Mode): void { dispatch('setMode', mode === next ? 'idle' : next); }
  function setCount(type: KeysiteType, side: Side, event: Event): void { dispatch('setCount', { type, side, value: Number((event.currentTarget as HTMLInputElement).value) }); }
  function setSide(event: Event): void { dispatch('setAssignmentSide', (event.currentTarget as HTMLSelectElement).value as Side); }
  function setRole(event: Event): void { dispatch('setAssignmentRole', (event.currentTarget as HTMLSelectElement).value as 'rear' | 'close'); }
  function setUnit(side: Side, role: AircraftRole, event: Event): void { dispatch('setUnit', { side, role, value: (event.currentTarget as HTMLInputElement).value }); }
  function chooseDesignFile(event: Event): void {
    const input = event.currentTarget as HTMLInputElement;
    const file = input.files?.[0];
    input.value = '';
    if (file) dispatch('importDesign', file);
  }
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
    <div class="step">2 · Paint territory</div>
    <span class="muted">Paint or erase one resolution-5 H3 cell at a time.</span>
    <div class="row"><label class="paint-setting">Side<select value={assignmentSide} disabled={paintErase} on:change={setSide}><option value="blue">BLU</option><option value="red">RED</option></select></label><label class="paint-setting">Role<select value={assignmentRole} disabled={paintErase} on:change={setRole}><option value="rear">Rear</option><option value="close">Close</option></select></label></div>
    <div class="row"><button class:active={mode === 'paint'} on:click={() => toggle('paint')}>{mode === 'paint' ? 'Painting…' : 'Paint on map'}</button><button class:active={paintErase} on:click={() => dispatch('setPaintErase', !paintErase)}>{paintErase ? 'Erasing…' : 'Erase cells'}</button></div>
    <div class="territory-counts"><span>BLU rear {blueRearCount} · close {blueCloseCount}</span><span>RED rear {redRearCount} · close {redCloseCount}</span></div>
    <span class="muted">Counts are painted resolution-5 cells. Turn painting off to pan the map.</span>
  </section>
  <section class:disabled={!terrain || !osmLoaded}>
    <div class="step">3 · Main airbases</div>
    <span class="muted">Choose an airbase inside painted territory for each side.</span>
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
    <button class="primary" disabled={!canGenerate} on:click={() => dispatch('generate')}>{generating ? 'Building…' : 'Generate .miz'}</button>{#if generateResult}<span class="ok">{generateResult}</span>{/if}
    <div class="row"><button disabled={!terrain || loadingOsm} on:click={() => dispatch('exportDesign')}>Save design (GeoJSON)</button><button on:click={() => importInput.click()}>Load design (GeoJSON)</button></div>
    <input class="file-input" bind:this={importInput} type="file" accept=".geojson,.json,application/geo+json,application/json" aria-label="Choose a saved design GeoJSON file" on:change={chooseDesignFile} />
    {#if designError}<span class="error">{designError}</span>{:else if designResult}<span class="ok">{designResult}</span>{/if}
  </section>
  <section><button on:click={() => dispatch('reset')}>Reset distribution</button></section>
  <footer><button class="manual" on:click={() => dispatch('openManual')}>▣ Operations Manual — how to play &amp; edit</button><p>Paint H3 territory for BLU and RED as rear or close, select each side’s main airbase, then generate and tune the keysite network.</p></footer>
</aside>

<style>
  .panel { width:330px; max-height:100%; overflow:auto; padding:0; background:var(--panel); color:var(--ink); } header,section { display:flex; flex-wrap:wrap; gap:7px; padding:11px 14px; border-bottom:1px solid var(--edge); } .brand{display:flex;align-items:center;gap:10px}.mark{color:var(--phosphor);font:1.15rem var(--font-hud);letter-spacing:-.15em;text-shadow:var(--glow)} h1,.step { width:100%; margin:0; font:.76rem var(--font-hud); letter-spacing:.13em; color:var(--phosphor); } header h1{font-size:.98rem;color:var(--phosphor-hot)} header span,.muted { font-size:.73rem; color:var(--muted); } .hint{margin:0;padding:8px 14px;background:rgba(246,166,35,.06);border-bottom:1px solid var(--edge);font-size:.76rem;line-height:1.4}.hint span{color:var(--amber);margin-right:4px} select,input { background:var(--panel-2); border:1px solid var(--edge); color:var(--ink); padding:5px; } select { width:100%; } button { background:var(--panel-2); color:var(--ink); border:1px solid var(--edge); padding:6px 8px; cursor:pointer; } button.primary,button.active { color:var(--phosphor-hot); border-color:var(--edge-hot); background:var(--accent-dim); } button:disabled { opacity:.45; cursor:default; } .disabled { opacity:.48; pointer-events:none; } .row,.territory-counts,.mains,.list { display:flex; gap:6px; width:100%; flex-wrap:wrap; } .row button { flex:1; } .paint-setting { flex:1; min-width:0; font-size:.72rem; } .territory-counts span,.mains span { padding:4px 6px; border:1px solid var(--edge); font-size:.7rem; } .blue { color:var(--friendly); } .red { color:var(--hostile); } .counts { width:100%; } .head,.count { display:grid; grid-template-columns:1fr 44px 44px; gap:5px; align-items:center; font-size:.72rem; margin:3px 0; } .count i,.site i { display:inline-block; width:8px; height:8px; transform:rotate(45deg); margin-right:5px; } .list > div { flex:1; min-width:0; } .site { display:flex; align-items:center; gap:4px; font-size:.68rem; cursor:pointer; padding:3px; } .site span { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; flex:1; } .site button,.mains button { padding:0 4px; } .error { color:#ffd6d8; border:1px solid var(--hostile); padding:6px; font-size:.72rem; } .ok { color:var(--phosphor-hot); font-size:.72rem; } .badge { font-size:.68rem; padding:3px 6px; border:1px solid var(--edge); } .bake{display:flex;align-items:center;gap:7px;width:100%;font-size:.76rem}.bake input{width:auto;accent-color:var(--phosphor)}.file-input{display:none}.units{width:100%}.units summary{cursor:pointer;color:var(--phosphor-dim);font:.7rem var(--font-hud);letter-spacing:.1em;text-transform:uppercase}.units-grid{display:flex;flex-direction:column;gap:3px;margin:7px 0}.urow{display:grid;grid-template-columns:1fr 92px 92px;gap:5px;align-items:center;font-size:.68rem}.urow input{min-width:0;width:100%;box-sizing:border-box;font-size:.68rem}.uhead{text-align:center;font: .62rem var(--font-hud)}.unit-actions{display:flex;gap:6px;align-items:center}.unit-actions .muted{flex:1}.manual{width:100%;color:var(--phosphor-hot);border-color:var(--edge-hot);background:var(--accent-dim)}footer{padding:11px 14px;color:var(--muted);font-size:.7rem;line-height:1.4}footer p{margin:8px 0 0}
  @media(max-width:720px){.panel{width:100%;max-height:100vh}.urow{grid-template-columns:1fr 88px 88px}button,select,input{min-height:36px}}
</style>
