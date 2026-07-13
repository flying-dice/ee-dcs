<script lang="ts">
  // ── App: state owner + wiring for the EECH map generator ───────────────────────
  // Designer flow (top to bottom):
  //   terrain → bbox → frontline → main airbases (click DCS rings) → populate
  //   keysites (per-type counts, shuffle, add/remove) → .miz.
  // Airbase zones are real DCS airfields; FARPs + support sites come from OSM. Nothing
  // is selected until both mains + a frontline exist (buildKeysites gate).
  import { onMount, onDestroy } from 'svelte';
  import MapView from './components/MapView.svelte';
  import type { Mode } from './components/MapView.svelte';
  import ControlPanel from './components/ControlPanel.svelte';
  import type { ProjBadge, SideSummary } from './components/ControlPanel.svelte';
  import Manual from './components/Manual.svelte';
  import { TERRAINS, terrainById, bboxInsideTerrain } from './lib/terrains';
  import { validateProjection } from './lib/projection';
  import { fetchOsm } from './lib/osm';
  import { classifyFeatures } from './lib/classify';
  import {
    buildKeysites,
    canBuild,
    blueSignFrom,
    sideOfFrontline,
    airbaseId,
    candidateId,
    DEFAULT_COUNTS,
  } from './lib/balance';
  import { buildMiz, filenameFor, keysitesToZones } from './lib/miz';
  import { DEFAULT_UNIT_TYPES } from './lib/units';
  import type { UnitTypes, AircraftRole } from './lib/units';
  import type {
    Terrain,
    BBox,
    LatLon,
    CandidateKeysite,
    Keysite,
    KeysiteType,
    Side,
    CountConfig,
    AddedKeysite,
    AirbasePoint,
  } from './lib/types';

  // Shared type palette (passed to both children so legend + markers agree).
  const TYPE_COLORS: Record<KeysiteType, string> = {
    airbase: '#e2e8f0',
    farp: '#a78bfa',
    factory: '#f59e0b',
    refinery: '#f97316',
    port: '#38bdf8',
    radar: '#14b8a6',
    power: '#ec4899',
    command: '#f43f5e',
  };

  const projChecks = validateProjection();

  // ── state ──────────────────────────────────────────────────────────────────────
  let selectedTerrainId = '';
  let bbox: BBox | null = null;
  let frontline: LatLon[] = [];
  let frontlineComplete = false;
  let mainBlue: AirbasePoint | null = null;
  let mainRed: AirbasePoint | null = null;

  let osmRaw: CandidateKeysite[] = []; // fetched once per bbox, reused across shuffles
  let osmFetched = false;
  let loadingOsm = false;
  let osmError: string | null = null;
  let populated = false; // candidates generated (after mains + frontline)

  let counts: CountConfig = structuredClone(DEFAULT_COUNTS); // APPLIED counts — drive the build
  let draftCounts: CountConfig = structuredClone(DEFAULT_COUNTS); // edited freely; committed on Apply
  let seed = 1; // shuffle seed
  let removed: string[] = []; // hard blocklist of ids
  let added: AddedKeysite[] = []; // forced-in ids

  let mode: Mode = 'idle';
  let generating = false;
  let generateResult: string | null = null;
  let bakeCampaign = true;
  let unitTypes: UnitTypes = structuredClone(DEFAULT_UNIT_TYPES);
  let showManual = false;
  // Mobile control-drawer open state. No-op on desktop (the panel is always shown there);
  // on a phone it slides the panel in/out so the map is reachable for drawing.
  let panelOpen = true;
  // Focus request from the list → MapView pans to + flashes the keysite. The bump
  // counter makes re-clicking the same row re-fire the flash.
  let focus: { id: string; n: number } | null = null;
  let focusN = 0;

  // ── derived ──────────────────────────────────────────────────────────────────
  $: terrain = selectedTerrainId ? terrainById(selectedTerrainId) ?? null : null;
  $: bboxValid = !!(bbox && terrain && bboxInsideTerrain(bbox, terrain));
  $: blueSign = blueSignFrom(mainBlue, frontline);
  $: canPopulate = !!terrain && bboxValid && canBuild({ mainBlue, mainRed, frontline });

  $: projBadge = terrain ? computeProjBadge(terrain) : null;
  function computeProjBadge(t: Terrain): ProjBadge {
    if (!t.projectionValidated) return { text: 'projection unvalidated', tone: 'amber' };
    const checks = projChecks.filter((c) => c.terrain === t.id);
    if (checks.length === 0) return { text: 'projection unvalidated', tone: 'amber' };
    const maxErr = Math.max(...checks.map((c) => c.errorM));
    const ok = checks.every((c) => c.ok);
    return { text: `projection ${ok ? '✓' : '✗'} ${maxErr.toFixed(1)} m`, tone: ok ? 'green' : 'red' };
  }

  // The live keysite set. Empty until populated; then rebuilds on any input change.
  $: keysites =
    populated && terrain
      ? buildKeysites({
          bbox: bbox!,
          frontline,
          airbases: terrain.airbases,
          mainBlue,
          mainRed,
          osm: osmRaw,
          counts,
          seed,
          removed,
          added,
        })
      : [];
  $: selectedIds = new Set(keysites.map((k) => k.id));

  function summarize(ks: Keysite[], side: Side): SideSummary {
    const s = ks.filter((k) => k.side === side);
    return {
      airbases: s.filter((k) => k.type === 'airbase').length,
      farps: s.filter((k) => k.type === 'farp').length,
      total: s.length,
    };
  }
  $: blueSummary = summarize(keysites, 'blue');
  $: redSummary = summarize(keysites, 'red');
  $: canGenerate =
    !!terrain &&
    keysites.length > 0 &&
    blueSummary.airbases >= 1 &&
    redSummary.airbases >= 1 &&
    !generating;

  const MODE_LABELS: Record<Mode, string> = {
    idle: 'STANDBY',
    bbox: 'DRAW AREA',
    'bbox-edit': 'EDIT AREA',
    'frontline-edit': 'EDIT FLOT',
    frontline: 'DRAW FLOT',
    'main-blue': 'SET BLU AB',
    'main-red': 'SET RED AB',
    edit: 'EDIT SITES',
  };
  $: modeLabel = MODE_LABELS[mode] ?? 'STANDBY';

  $: hint = computeHint(mode, terrain, bboxValid, canPopulate, populated);
  function computeHint(
    m: Mode,
    t: Terrain | null,
    valid: boolean,
    canPop: boolean,
    pop: boolean,
  ): string {
    if (!t) return 'Start by picking a DCS theatre.';
    switch (m) {
      case 'bbox':
        return 'Drag on the map to draw the theatre-area rectangle.';
      case 'bbox-edit':
        return 'Drag the box to move it, or its edges/corners to resize. Tap ✓ Done when it fits.';
      case 'frontline':
        return 'Click to add frontline vertices; double-click or Enter to finish.';
      case 'frontline-edit':
        return 'Drag a vertex to move it, or a hollow midpoint to add one. Tap ✓ Done when set.';
      case 'main-blue':
        return 'Click a DCS airbase ring to set the BLUE main.';
      case 'main-red':
        return 'Click a DCS airbase ring to set the RED main.';
      case 'edit':
        return 'Click a site to remove it, or an unpicked airbase/marker to add it.';
      default:
        if (!bbox) return 'Draw the theatre bbox (step 2).';
        if (!valid) return 'The bbox falls outside the terrain — redraw it fully inside.';
        if (!canPop) return 'Draw a frontline and set both main airbases (steps 3–4).';
        if (!pop) return 'Populate keysites (step 5) to generate the network.';
        return 'Tune counts, Shuffle to re-roll, or Edit on map to add/remove.';
    }
  }

  // ── event handlers ─────────────────────────────────────────────────────────────
  function onSelectTerrain(id: string): void {
    selectedTerrainId = id;
    bbox = null;
    resetDownstream();
    mode = 'idle';
  }

  function resetDownstream(): void {
    frontline = [];
    frontlineComplete = false;
    mainBlue = null;
    mainRed = null;
    osmRaw = [];
    osmFetched = false;
    osmError = null;
    populated = false;
    removed = [];
    added = [];
    generateResult = null;
  }

  function onSetMode(m: Mode): void {
    if (m === 'frontline' && frontlineComplete) {
      frontline = [];
      frontlineComplete = false;
    }
    mode = m;
    // Entering a map-gesture mode dismisses the mobile drawer so the map is reachable.
    if (m !== 'idle') panelOpen = false;
  }

  function onBbox(b: BBox): void {
    bbox = b;
    resetDownstream();
    mode = 'bbox-edit'; // stay editable — drag the handles until confirmed
    panelOpen = false; // keep the map reachable for adjusting the box
  }

  function onBboxEdit(b: BBox): void {
    bbox = b; // live update while dragging handles; validity recomputes
  }

  function onConfirmBbox(): void {
    mode = 'idle';
    panelOpen = true; // box locked — back to the panel for the next step
  }

  function onFrontlinePoint(p: LatLon): void {
    frontline = [...frontline, p];
    frontlineComplete = false;
  }

  function onFinishFrontline(): void {
    if (frontline.length >= 2) {
      frontlineComplete = true;
      mode = 'idle';
      panelOpen = true;
    }
  }

  function onClearFrontline(): void {
    frontline = [];
    frontlineComplete = false;
    if (mode === 'frontline' || mode === 'frontline-edit') mode = 'idle';
  }

  function onFrontlineEdit(line: LatLon[]): void {
    frontline = line; // live update while dragging vertices / adding midpoints
  }

  function onConfirmFrontline(): void {
    mode = 'idle';
    panelOpen = true;
  }

  // A DCS airbase ring was clicked to designate a side's main.
  function onDesignateMain(ab: AirbasePoint): void {
    if (mode === 'main-blue') mainBlue = ab;
    else if (mode === 'main-red') mainRed = ab;
    mode = 'idle';
    panelOpen = true;
  }

  function onClearMain(side: Side): void {
    if (side === 'blue') mainBlue = null;
    else mainRed = null;
  }

  async function onPopulate(): Promise<void> {
    if (!canPopulate || !bbox) return;
    osmError = null;
    generateResult = null;
    if (!osmFetched) {
      loadingOsm = true;
      try {
        const features = await fetchOsm(bbox);
        osmRaw = classifyFeatures(features);
        osmFetched = true;
      } catch (e) {
        osmError = `Overpass request failed: ${(e as Error).message}`;
        loadingOsm = false;
        return;
      }
      loadingOsm = false;
    }
    counts = structuredClone(draftCounts); // first build uses the current draft counts
    populated = true;
    mode = 'idle';
  }

  function onShuffle(): void {
    if (!populated) return;
    seed = (seed + 1) | 0;
  }

  // Count inputs edit a DRAFT only (no rebuild); Apply commits it so buildKeysites runs once.
  function onSetCount(detail: { type: KeysiteType; side: Side; value: number }): void {
    const v = Math.max(0, Math.min(20, Math.round(detail.value || 0)));
    draftCounts = { ...draftCounts, [detail.type]: { ...draftCounts[detail.type], [detail.side]: v } };
  }
  function countsEqual(a: CountConfig, b: CountConfig): boolean {
    return (Object.keys(a) as KeysiteType[]).every((t) => a[t].blue === b[t].blue && a[t].red === b[t].red);
  }
  $: countsDirty = !countsEqual(draftCounts, counts);
  function onApplyCounts(): void {
    counts = structuredClone(draftCounts); // one rebuild via the reactive keysites
  }

  function onSetUnit(d: { side: Side; role: AircraftRole; value: string }): void {
    unitTypes = { ...unitTypes, [d.side]: { ...unitTypes[d.side], [d.role]: d.value } };
  }
  function onResetUnits(): void {
    unitTypes = structuredClone(DEFAULT_UNIT_TYPES);
  }

  function onRemoveKeysite(id: string): void {
    if (!removed.includes(id)) removed = [...removed, id];
    added = added.filter((a) => a.id !== id);
  }

  function onFocusKeysite(id: string): void {
    focusN += 1;
    focus = { id, n: focusN };
  }

  // Toggle a DCS airbase's membership (edit mode click on a ring).
  function onToggleAirbase(ab: AirbasePoint): void {
    const id = airbaseId(ab);
    if (selectedIds.has(id)) {
      onRemoveKeysite(id);
    } else {
      removed = removed.filter((r) => r !== id);
      const side: Side = sideOfFrontline(ab.latlon, frontline) === blueSign ? 'blue' : 'red';
      if (!added.some((a) => a.id === id)) {
        added = [
          ...added,
          { id, type: 'airbase', side, latlon: ab.latlon, name: ab.name, tags: { category: ab.category } },
        ];
      }
    }
  }

  // Toggle an OSM candidate's membership (edit mode click on a dot).
  function onToggleCandidate(c: CandidateKeysite): void {
    const id = candidateId(c);
    if (selectedIds.has(id)) {
      onRemoveKeysite(id);
    } else {
      removed = removed.filter((r) => r !== id);
      const side: Side = sideOfFrontline(c.latlon, frontline) === blueSign ? 'blue' : 'red';
      if (!added.some((a) => a.id === id)) {
        added = [
          ...added,
          { id, type: c.type, side, latlon: c.latlon, name: c.name, tags: c.source.tags },
        ];
      }
    }
  }

  function onReset(): void {
    frontline = [];
    frontlineComplete = false;
    mainBlue = null;
    mainRed = null;
    populated = false;
    removed = [];
    added = [];
    generateResult = null;
    mode = 'idle';
  }

  function downloadBlob(blob: Blob, name: string): void {
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function onGenerate(): Promise<void> {
    if (!terrain || !canGenerate) return;
    generating = true;
    generateResult = null;
    osmError = null;
    try {
      const blob = await buildMiz(keysites, terrain, { bakeCampaign, unitTypes });
      const name = filenameFor(terrain);
      downloadBlob(blob, name);
      generateResult = bakeCampaign
        ? `${name} — ${keysites.length} zones + campaign Lua baked in, ready to play in DCS`
        : `${name} — ${keysites.length} zones (no campaign Lua), add your own script`;
    } catch (e) {
      osmError = `Generate failed: ${(e as Error).message}`;
    } finally {
      generating = false;
    }
  }

  function onDownloadGeoJson(): void {
    if (!terrain || keysites.length === 0) return;
    const zones = keysitesToZones(keysites, terrain);
    const features: unknown[] = [];
    if (frontline.length >= 2) {
      features.push({
        type: 'Feature',
        properties: { kind: 'frontline' },
        geometry: { type: 'LineString', coordinates: frontline.map((p) => [p.lon, p.lat]) },
      });
    }
    for (const k of keysites) {
      features.push({
        type: 'Feature',
        properties: { kind: 'keysite', type: k.type, side: k.side, label: k.label, name: k.name, radiusM: k.radiusM },
        geometry: { type: 'Point', coordinates: [k.latlon.lon, k.latlon.lat] },
      });
    }
    for (const z of zones) {
      features.push({
        type: 'Feature',
        properties: { kind: 'zone', name: z.name, side: z.side, x: z.x, y: z.y, radius: z.radius },
      });
    }
    const fc = { type: 'FeatureCollection', properties: { terrain: terrain.id }, features };
    const blob = new Blob([JSON.stringify(fc, null, 2)], { type: 'application/geo+json' });
    downloadBlob(blob, `eech-${terrain.id.toLowerCase()}-design.geojson`);
  }

  function onKeydown(e: KeyboardEvent): void {
    if (e.key === 'Enter' && mode === 'frontline') {
      e.preventDefault();
      onFinishFrontline();
    }
  }
  onMount(() => window.addEventListener('keydown', onKeydown));
  onDestroy(() => window.removeEventListener('keydown', onKeydown));
</script>

<div class="app">
  <div class="map-wrap">
    <MapView
      {terrain}
      {bbox}
      {bboxValid}
      {frontline}
      {frontlineComplete}
      {blueSign}
      {keysites}
      {selectedIds}
      osm={populated ? osmRaw.filter((c) => c.type !== 'farp') : []}
      {mainBlue}
      {mainRed}
      {mode}
      {focus}
      typeColors={TYPE_COLORS}
      on:bbox={(e) => onBbox(e.detail)}
      on:bboxEdit={(e) => onBboxEdit(e.detail)}
      on:frontlinePoint={(e) => onFrontlinePoint(e.detail)}
      on:frontlineFinish={onFinishFrontline}
      on:frontlineEdit={(e) => onFrontlineEdit(e.detail)}
      on:designateMain={(e) => onDesignateMain(e.detail)}
      on:toggleAirbase={(e) => onToggleAirbase(e.detail)}
      on:toggleCandidate={(e) => onToggleCandidate(e.detail)}
    />
  </div>

  <div class="frame" aria-hidden="true">
    <span class="c tl"></span><span class="c tr"></span>
    <span class="c bl"></span><span class="c br"></span>
  </div>

  {#if mode === 'bbox-edit'}
    <button class="bbox-done" on:click={onConfirmBbox}>✓ Done — lock the area</button>
  {:else if mode === 'frontline-edit'}
    <button class="bbox-done" on:click={onConfirmFrontline}>✓ Done — lock the frontline</button>
  {/if}

  <aside class="island readout hud">
    <div class="rr"><span>THEATRE</span><b>{terrain ? terrain.label.toUpperCase() : '——'}</b></div>
    <div class="rr"><span>MODE</span><b>{modeLabel}</b></div>
    <div class="rr"><span>AIRFIELDS</span><b>{terrain ? terrain.airbases.length : '—'}</b></div>
    <div class="rr"><span>ZONES</span><b>{keysites.length || '—'}</b></div>
    <div class="rr split">
      <span class="fr">BLU {blueSummary.total}</span>
      <span class="ho">RED {redSummary.total}</span>
    </div>
  </aside>

  <!-- Mobile: FAB to open the control drawer, and a backdrop to close it -->
  <button class="panel-fab" class:hidden={panelOpen} on:click={() => (panelOpen = true)}>
    <span class="mark">◣◤</span> Controls
  </button>
  <button
    class="panel-backdrop"
    class:show={panelOpen}
    aria-label="Close controls"
    on:click={() => (panelOpen = false)}
  ></button>

  <div class="dock-left" class:open={panelOpen}>
    <button class="panel-close" aria-label="Close controls" on:click={() => (panelOpen = false)}>✕</button>
    <ControlPanel
      terrains={TERRAINS}
      {selectedTerrainId}
      {terrain}
      {projBadge}
      {mode}
      hasBbox={!!bbox}
      {bboxValid}
      frontlineCount={frontline.length}
      {frontlineComplete}
      mainBlueName={mainBlue?.name ?? null}
      mainRedName={mainRed?.name ?? null}
      {canPopulate}
      {populated}
      {loadingOsm}
      {osmError}
      counts={draftCounts}
      {countsDirty}
      {keysites}
      {blueSummary}
      {redSummary}
      {canGenerate}
      {generating}
      {generateResult}
      {bakeCampaign}
      {unitTypes}
      {hint}
      typeColors={TYPE_COLORS}
      on:selectTerrain={(e) => onSelectTerrain(e.detail)}
      on:setMode={(e) => onSetMode(e.detail)}
      on:confirmBbox={onConfirmBbox}
      on:finishFrontline={onFinishFrontline}
      on:clearFrontline={onClearFrontline}
      on:confirmFrontline={onConfirmFrontline}
      on:clearMain={(e) => onClearMain(e.detail)}
      on:populate={onPopulate}
      on:shuffle={onShuffle}
      on:setCount={(e) => onSetCount(e.detail)}
      on:applyCounts={onApplyCounts}
      on:setUnit={(e) => onSetUnit(e.detail)}
      on:resetUnits={onResetUnits}
      on:removeKeysite={(e) => onRemoveKeysite(e.detail)}
      on:focusKeysite={(e) => onFocusKeysite(e.detail)}
      on:reset={onReset}
      on:generate={onGenerate}
      on:downloadGeoJson={onDownloadGeoJson}
      on:setBakeCampaign={(e) => (bakeCampaign = e.detail)}
      on:openManual={() => (showManual = true)}
    />
  </div>

  {#if showManual}
    <Manual typeColors={TYPE_COLORS} on:close={() => (showManual = false)} />
  {/if}
</div>

<style>
  .app {
    position: relative;
    height: 100vh;
    width: 100vw;
    overflow: hidden;
    background: var(--void);
  }
  .map-wrap {
    position: absolute;
    inset: 0;
  }
  .dock-left {
    position: absolute;
    top: 14px;
    left: 14px;
    bottom: 14px;
    z-index: 500;
    display: flex;
    pointer-events: none;
  }
  .dock-left :global(.panel) { pointer-events: auto; }

  /* Mobile-only chrome — hidden on desktop, activated in the media query below. */
  .panel-fab,
  .panel-backdrop,
  .panel-close { display: none; }

  .readout {
    position: absolute;
    top: 14px;
    right: 14px;
    z-index: 500;
    width: 200px;
    padding: 10px 12px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    font-size: 0.72rem;
  }
  .readout .rr {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 8px;
    letter-spacing: 0.1em;
  }
  .readout .rr span { color: var(--ink-dim); }
  .readout .rr b {
    color: var(--phosphor);
    text-shadow: var(--glow);
    font-weight: 400;
    max-width: 120px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .readout .split {
    margin-top: 4px;
    padding-top: 6px;
    border-top: 1px solid var(--edge);
    justify-content: space-between;
  }
  .readout .fr { color: var(--friendly); }
  .readout .ho { color: var(--hostile); }

  .frame {
    position: absolute;
    inset: 8px;
    z-index: 450;
    pointer-events: none;
  }
  .frame .c {
    position: absolute;
    width: 26px;
    height: 26px;
    border: 2px solid var(--phosphor-dim);
    opacity: 0.5;
  }
  .frame .tl { top: 0; left: 0; border-right: 0; border-bottom: 0; }
  .frame .tr { top: 0; right: 0; border-left: 0; border-bottom: 0; }
  .frame .bl { bottom: 0; left: 0; border-right: 0; border-top: 0; }
  .frame .br { bottom: 0; right: 0; border-left: 0; border-top: 0; }

  /* Floating confirm for the editable theatre box. */
  .bbox-done {
    position: absolute;
    left: 50%;
    bottom: 22px;
    transform: translateX(-50%);
    z-index: 700;
    padding: 11px 18px;
    font-family: var(--font-hud);
    font-size: 0.82rem;
    letter-spacing: 0.1em;
    color: var(--void);
    background: var(--phosphor);
    border: 1px solid var(--phosphor-hot);
    border-radius: 4px;
    box-shadow: 0 6px 22px rgba(0, 0, 0, 0.55), var(--glow);
    cursor: pointer;
  }
  .bbox-done:hover { background: var(--phosphor-hot); }

  @media (max-width: 720px) {
    .readout { display: none; }

    /* Control panel becomes a left drawer that slides in and out. */
    .dock-left {
      top: 0;
      left: 0;
      bottom: 0;
      right: auto;
      width: min(390px, 92vw);
      z-index: 900;
      pointer-events: auto;
      transform: translateX(-102%);
      transition: transform 0.24s ease;
    }
    .dock-left.open { transform: translateX(0); }
    .dock-left :global(.panel) {
      width: 100%;
      max-height: 100%;
      border-radius: 0;
      box-shadow: 6px 0 24px rgba(0, 0, 0, 0.5);
    }

    /* Dimming backdrop behind the open drawer — tap to close. */
    .panel-backdrop {
      display: block;
      position: absolute;
      inset: 0;
      z-index: 850;
      margin: 0;
      padding: 0;
      border: 0;
      background: rgba(3, 8, 7, 0.5);
      opacity: 0;
      pointer-events: none;
      transition: opacity 0.24s ease;
    }
    .panel-backdrop.show { opacity: 1; pointer-events: auto; }

    /* Floating button to reopen the drawer (clear of the bottom-right zoom control). */
    .panel-fab {
      display: inline-flex;
      align-items: center;
      gap: 7px;
      position: absolute;
      left: 12px;
      bottom: 14px;
      z-index: 600;
      padding: 11px 15px;
      font-family: var(--font-hud);
      font-size: 0.8rem;
      letter-spacing: 0.14em;
      text-transform: uppercase;
      color: var(--phosphor-hot);
      background: rgba(8, 19, 17, 0.94);
      border: 1px solid var(--edge-hot);
      border-radius: 4px;
      text-shadow: var(--glow);
      box-shadow: 0 6px 20px rgba(0, 0, 0, 0.5);
    }
    .panel-fab.hidden { display: none; }
    .panel-fab .mark { color: var(--phosphor); letter-spacing: -0.15em; font-size: 1rem; }

    /* Close ✕ inside the drawer. */
    .panel-close {
      display: flex;
      align-items: center;
      justify-content: center;
      position: absolute;
      top: 8px;
      right: 16px;
      z-index: 20;
      width: 36px;
      height: 36px;
      padding: 0;
      font-size: 1rem;
      color: var(--phosphor);
      background: rgba(8, 19, 17, 0.9);
      border: 1px solid var(--edge);
      border-radius: 3px;
      pointer-events: auto;
    }
    .panel-close:hover { color: var(--hostile); border-color: var(--hostile); }
  }
</style>
