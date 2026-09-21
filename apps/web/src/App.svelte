<script lang="ts">
  import MapView from './components/MapView.svelte';
  import type { Mode } from './components/MapView.svelte';
  import ControlPanel from './components/ControlPanel.svelte';
  import type { ProjBadge, SideSummary } from './components/ControlPanel.svelte';
  import Manual from './components/Manual.svelte';
  import { TERRAINS, terrainById } from './lib/terrains';
  import { validateProjection } from './lib/projection';
  import { loadTheatreOsm } from './lib/osm';
  import { classifyFeatures } from './lib/classify';
  import { buildKeysites, canBuild, airbaseId, candidateId, DEFAULT_COUNTS } from './lib/balance';
  import { buildMiz, filenameFor, keysitesToZones } from './lib/miz';
  import { buildTerritoryPlan, countTerritories, paintableCells, territoryAt } from './lib/territory';
  import { activeAreaBounds } from './lib/active_area';
  import { DEFAULT_UNIT_TYPES } from './lib/units';
  import type { UnitTypes, AircraftRole } from './lib/units';
  import type { Terrain, CandidateKeysite, Keysite, KeysiteType, Side, CountConfig, AddedKeysite, AirbasePoint, OsmFeature, LatLon, TerritoryPlan, TerritoryAssignment } from './lib/types';

  const TYPE_COLORS: Record<KeysiteType, string> = { airbase:'#e2e8f0', farp:'#a78bfa', factory:'#f59e0b', refinery:'#f97316', port:'#38bdf8', radar:'#14b8a6', power:'#ec4899', command:'#f43f5e', depot:'#84cc16', fuel:'#fb923c' };
  const projChecks = validateProjection();
  let selectedTerrainId = '';
  let mainBlue: AirbasePoint | null = null;
  let mainRed: AirbasePoint | null = null;
  let theatreOsm: OsmFeature[] = [];
  let cellAssignments: Record<string, TerritoryAssignment> = {};
  let paintErase = false;
  let loadingOsm = false;
  let osmLoaded = false;
  let osmError: string | null = null;
  let mainError: string | null = null;
  let populated = false;
  let counts: CountConfig = structuredClone(DEFAULT_COUNTS);
  let draftCounts: CountConfig = structuredClone(DEFAULT_COUNTS);
  let seed = 1;
  let removed: string[] = [];
  let added: AddedKeysite[] = [];
  let positionOverrides: Record<string, LatLon> = {};
  let mode: Mode = 'idle';
  let generating = false;
  let generateResult: string | null = null;
  let bakeCampaign = true;
  let unitTypes: UnitTypes = structuredClone(DEFAULT_UNIT_TYPES);
  let showManual = false;
  let panelOpen = true;
  let focus: { id: string; n: number } | null = null;
  let focusN = 0;
  let assignmentSide: Side = 'blue';
  let assignmentRole: 'rear' | 'close' = 'rear';

  $: terrain = selectedTerrainId ? terrainById(selectedTerrainId) ?? null : null;
  $: activeBounds = terrain ? activeAreaBounds(terrain) : null;
  // The core contract changes assignments from a simple side map to an explicit side/role map.
  $: territoryPlan = buildTerritoryPlan(cellAssignments);
  $: areaOsm = theatreOsm.filter((feature) => !!territoryAt(territoryPlan, feature.latlon));
  $: osmRaw = classifyFeatures(areaOsm);
  $: mapCandidates = classifyFeatures(theatreOsm).filter((item) => item.type !== 'farp');
  $: canPopulate = !!terrain && canBuild({ mainBlue, mainRed, territoryPlan });
  $: keysites = populated && terrain ? buildKeysites({ airbases: terrain.airbases, mainBlue, mainRed, osm: osmRaw, counts, seed, removed, added, positionOverrides, territoryPlan }) : [];
  $: selectedIds = new Set(keysites.map((keysite) => keysite.id));
  $: blueSummary = summarize(keysites, 'blue');
  $: redSummary = summarize(keysites, 'red');
  $: canGenerate = !!terrain && keysites.length > 0 && blueSummary.airbases > 0 && redSummary.airbases > 0 && !generating;
  $: countsDirty = !countsEqual(draftCounts, counts);
  $: projBadge = terrain ? projectionBadge(terrain) : null;
  $: blueRearCount = countTerritories(territoryPlan, 'blue', 'rear');
  $: blueCloseCount = countTerritories(territoryPlan, 'blue', 'close');
  $: redRearCount = countTerritories(territoryPlan, 'red', 'rear');
  $: redCloseCount = countTerritories(territoryPlan, 'red', 'close');
  $: hasBlueTerritory = territoryPlan.ownerCounts.blue > 0;
  $: hasRedTerritory = territoryPlan.ownerCounts.red > 0;
  $: modeLabel = mode === 'main-blue' ? 'SET BLU AB' : mode === 'main-red' ? 'SET RED AB' : mode === 'edit' ? 'EDIT SITES' : mode === 'paint' ? 'PAINT H3' : 'STANDBY';
  $: hint = workflowHint(terrain, loadingOsm, osmLoaded, mode, hasBlueTerritory, hasRedTerritory, mainBlue, mainRed, populated);

  function summarize(keysites: Keysite[], side: Side): SideSummary { const sites = keysites.filter((keysite) => keysite.side === side); return { airbases: sites.filter((keysite) => keysite.type === 'airbase').length, farps: sites.filter((keysite) => keysite.type === 'farp').length, total: sites.length }; }
  function projectionBadge(item: Terrain): ProjBadge { const checks = projChecks.filter((check) => check.terrain === item.id); if (!item.projectionValidated || checks.length === 0) return { text:'projection unvalidated', tone:'amber' }; const max = Math.max(...checks.map((check) => check.errorM)); return { text:`projection ${checks.every((check) => check.ok) ? '✓' : '✗'} ${max.toFixed(1)} m`, tone: checks.every((check) => check.ok) ? 'green' : 'red' }; }
  function workflowHint(currentTerrain: Terrain | null, isLoading: boolean, isLoaded: boolean, currentMode: Mode, blueReady: boolean, redReady: boolean, blueMain: AirbasePoint | null, redMain: AirbasePoint | null, hasPopulated: boolean): string {
    if (!currentTerrain) return 'Start by picking a DCS theatre.';
    if (isLoading) return 'Loading the baked DCS and OpenStreetMap theatre data.';
    if (!isLoaded) return 'The theatre data must load before distribution can begin.';
    if (currentMode === 'main-blue') return 'Click a BLUE-owned airbase ring to set the BLUE main.';
    if (currentMode === 'main-red') return 'Click a RED-owned airbase ring to set the RED main.';
    if (currentMode === 'edit') return 'Drag generated sites or click markers to tune the keysite network.';
    if (currentMode === 'paint') return 'Drag across H3 cells to paint the selected side and role; choose Erase to clear.';
    if (!blueReady || !redReady) return 'Select a brush and paint BLU/RED rear and close cells.';
    if (!blueMain || !redMain) return 'Select one main airbase inside each side’s assigned territory.';
    if (!hasPopulated) return 'Populate keysites from the assigned territories and operational roles.';
    return 'Tune counts, shuffle placement, edit sites on the map, or generate the mission.';
  }
  function countsEqual(first: CountConfig, second: CountConfig): boolean { return (Object.keys(first) as KeysiteType[]).every((type) => first[type].blue === second[type].blue && first[type].red === second[type].red); }
  function invalidate(): void { populated = false; removed = []; added = []; positionOverrides = {}; generateResult = null; }
  async function onSelectTerrain(id: string): Promise<void> {
    selectedTerrainId = id; mainBlue = null; mainRed = null; theatreOsm = []; cellAssignments = {}; osmLoaded = false; loadingOsm = true; osmError = null; mainError = null; invalidate();
    try { const osm = await loadTheatreOsm(id); theatreOsm = osm.features; osmLoaded = true; } catch (error) { osmError = (error as Error).message; } finally { loadingOsm = false; }
  }
  function onSetMode(next: Mode): void { mode = mode === next ? 'idle' : next; mainError = null; if (mode !== 'idle') panelOpen = false; }
  function onDesignateMain(airbase: AirbasePoint): void {
    const requested: Side | null = mode === 'main-blue' ? 'blue' : mode === 'main-red' ? 'red' : null;
    if (!requested) return;
    const territory = territoryAt(territoryPlan, airbase.latlon);
    if (!territory || territory.owner !== requested) { mainError = `${airbase.name} is not inside a ${requested.toUpperCase()} assigned territory.`; return; }
    if (requested === 'blue') mainBlue = airbase; else mainRed = airbase;
    mainError = null; mode = 'idle'; panelOpen = true; invalidate();
  }
  function onClearMain(side: Side): void { if (side === 'blue') mainBlue = null; else mainRed = null; invalidate(); }
  function onPaintCell(cell: string): void {
    if (!terrain || !activeBounds) return;
    const children = paintableCells(cell, terrain, activeBounds);
    if (children.length === 0) return;
    const next = { ...cellAssignments };
    let changed = false;
    for (const child of children) {
      const previous = next[child];
      if (paintErase) {
        if (previous) { delete next[child]; changed = true; }
      } else if (previous?.side !== assignmentSide || previous.role !== assignmentRole) {
        next[child] = { side: assignmentSide, role: assignmentRole };
        changed = true;
      }
    }
    if (!changed) return;
    cellAssignments = next;
    const plan = buildTerritoryPlan(next);
    if (mainBlue && territoryAt(plan, mainBlue.latlon)?.owner !== 'blue') mainBlue = null;
    if (mainRed && territoryAt(plan, mainRed.latlon)?.owner !== 'red') mainRed = null;
    invalidate();
  }
  function onPopulate(): void { if (!canPopulate) return; counts = structuredClone(draftCounts); populated = true; mode = 'idle'; }
  function onSetCount(detail: { type: KeysiteType; side: Side; value: number }): void { const value = Math.max(0, Math.min(20, Math.round(detail.value || 0))); draftCounts = { ...draftCounts, [detail.type]: { ...draftCounts[detail.type], [detail.side]: value } }; }
  function onApplyCounts(): void { counts = structuredClone(draftCounts); }
  function onSetUnit(detail: { side: Side; role: AircraftRole; value: string }): void { unitTypes = { ...unitTypes, [detail.side]: { ...unitTypes[detail.side], [detail.role]: detail.value } }; }
  function onResetUnits(): void { unitTypes = structuredClone(DEFAULT_UNIT_TYPES); }
  function onShuffle(): void { seed = (seed + 1) | 0; }
  function onRemoveKeysite(id: string): void { if (!removed.includes(id)) removed = [...removed, id]; added = added.filter((item) => item.id !== id); }
  function onToggleAirbase(airbase: AirbasePoint): void { const id = airbaseId(airbase); const territory = territoryAt(territoryPlan, airbase.latlon); if (!territory) return; if (selectedIds.has(id)) onRemoveKeysite(id); else { removed = removed.filter((item) => item !== id); added = [...added, { id, type:'airbase', side:territory.owner, latlon:airbase.latlon, name:airbase.name, tags:{ category:airbase.category } }]; } }
  function onToggleCandidate(candidate: CandidateKeysite): void { const id = candidateId(candidate); const territory = territoryAt(territoryPlan, candidate.latlon); if (!territory) return; if (selectedIds.has(id)) onRemoveKeysite(id); else { removed = removed.filter((item) => item !== id); added = [...added, { id, type:candidate.type, side:territory.owner, latlon:candidate.latlon, name:candidate.name, tags:candidate.source.tags }]; } }
  function onMoveKeysite(detail: { id: string; latlon: LatLon }): void { const keysite = keysites.find((item) => item.id === detail.id); if (!keysite || keysite.locationTied || territoryAt(territoryPlan, detail.latlon)?.owner !== keysite.side) return; positionOverrides = { ...positionOverrides, [detail.id]: detail.latlon }; }
  function onFocusKeysite(id: string): void { focus = { id, n: ++focusN }; }
  function downloadBlob(blob: Blob, name: string): void { const url = URL.createObjectURL(blob); const anchor = document.createElement('a'); anchor.href = url; anchor.download = name; anchor.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); }
  async function onGenerate(): Promise<void> { if (!terrain || !canGenerate) return; generating = true; try { const blob = await buildMiz(keysites, terrain, { bakeCampaign, unitTypes }); const name = filenameFor(terrain); downloadBlob(blob, name); generateResult = bakeCampaign ? `${name} — ${keysites.length} zones + campaign Lua, ready to play in DCS` : `${name} — ${keysites.length} zones (no campaign Lua)`; } catch (error) { osmError = `Generate failed: ${(error as Error).message}`; } finally { generating = false; } }
  function onDownloadGeoJson(): void { if (!terrain) return; const zones = keysitesToZones(keysites, terrain); const features = keysites.map((keysite) => ({ type:'Feature', properties:{ kind:'keysite', type:keysite.type, side:keysite.side, name:keysite.name }, geometry:{ type:'Point', coordinates:[keysite.latlon.lon, keysite.latlon.lat] } })); downloadBlob(new Blob([JSON.stringify({ type:'FeatureCollection', properties:{ terrain:terrain.id, zones }, features }, null, 2)], { type:'application/geo+json' }), `eech-${terrain.id.toLowerCase()}-design.geojson`); }
  function onReset(): void { mainBlue = null; mainRed = null; cellAssignments = {}; mode = 'idle'; mainError = null; invalidate(); }
</script>

<div class="app">
  <div class="map-wrap"><MapView {terrain} {activeBounds} {keysites} {selectedIds} osm={mapCandidates} {mainBlue} {mainRed} {mode} {paintErase} {assignmentSide} {assignmentRole} {territoryPlan} {focus} typeColors={TYPE_COLORS} on:designateMain={(event) => onDesignateMain(event.detail)} on:toggleAirbase={(event) => onToggleAirbase(event.detail)} on:toggleCandidate={(event) => onToggleCandidate(event.detail)} on:moveKeysite={(event) => onMoveKeysite(event.detail)} on:paintCell={(event) => onPaintCell(event.detail)} /></div>
  <div class="frame" aria-hidden="true"><i class="tl"></i><i class="tr"></i><i class="bl"></i><i class="br"></i></div>
  <aside class="island readout hud">
    <div><span>THEATRE</span><b>{terrain ? terrain.label.toUpperCase() : '——'}</b></div><div><span>MODE</span><b>{modeLabel}</b></div><div><span>AIRFIELDS</span><b>{terrain ? terrain.airbases.length : '—'}</b></div><div><span>ZONES</span><b>{keysites.length || '—'}</b></div><div class="split"><span class="blue">BLU {blueSummary.total}</span><span class="red">RED {redSummary.total}</span></div>
  </aside>
  <button class="panel-fab" class:hidden={panelOpen} on:click={() => panelOpen = true}><span>◣◤</span> Controls</button>
  <button class="panel-backdrop" class:show={panelOpen} aria-label="Close controls" on:click={() => panelOpen = false}></button>
  <aside class="dock-left" class:open={panelOpen}>
    <button class="panel-close" aria-label="Close controls" on:click={() => panelOpen = false}>✕</button>
    <ControlPanel terrains={TERRAINS} {selectedTerrainId} {terrain} {projBadge} {mode} mainBlueName={mainBlue?.name ?? null} mainRedName={mainRed?.name ?? null} {canPopulate} {populated} {loadingOsm} {osmLoaded} {osmError} {mainError} {blueRearCount} {blueCloseCount} {redRearCount} {redCloseCount} {hasBlueTerritory} {hasRedTerritory} counts={draftCounts} {countsDirty} {keysites} {blueSummary} {redSummary} {canGenerate} {generating} {generateResult} {bakeCampaign} {unitTypes} {hint} typeColors={TYPE_COLORS} {paintErase} {assignmentSide} {assignmentRole} on:selectTerrain={(event) => onSelectTerrain(event.detail)} on:setMode={(event) => onSetMode(event.detail)} on:clearMain={(event) => onClearMain(event.detail)} on:populate={onPopulate} on:shuffle={onShuffle} on:setCount={(event) => onSetCount(event.detail)} on:applyCounts={onApplyCounts} on:setUnit={(event) => onSetUnit(event.detail)} on:resetUnits={onResetUnits} on:removeKeysite={(event) => onRemoveKeysite(event.detail)} on:focusKeysite={(event) => onFocusKeysite(event.detail)} on:reset={onReset} on:generate={onGenerate} on:downloadGeoJson={onDownloadGeoJson} on:setBakeCampaign={(event) => bakeCampaign = event.detail} on:openManual={() => showManual = true} on:setAssignmentSide={(event) => assignmentSide = event.detail} on:setAssignmentRole={(event) => assignmentRole = event.detail} on:setPaintErase={(event) => paintErase = event.detail} />
  </aside>
  {#if showManual}<Manual typeColors={TYPE_COLORS} on:close={() => showManual = false} />{/if}
</div>

<style>
  .app,.map-wrap { position:fixed; inset:0; }
  .dock-left { position:fixed; left:14px; top:14px; bottom:14px; z-index:800; display:flex; pointer-events:none; }
  .dock-left :global(.panel), .panel-close { pointer-events:auto; }
  .readout { position:absolute; right:14px; top:14px; z-index:500; width:200px; padding:10px 12px; display:flex; flex-direction:column; gap:4px; font-size:.72rem; }
  .readout > div { display:flex; justify-content:space-between; gap:8px; letter-spacing:.1em; }
  .readout span { color:var(--ink-dim); } .readout b { color:var(--phosphor); font-weight:400; text-shadow:var(--glow); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .readout .split { border-top:1px solid var(--edge); margin-top:4px; padding-top:6px; } .readout .blue { color:var(--friendly); } .readout .red { color:var(--hostile); }
  .frame { position:absolute; inset:8px; z-index:450; pointer-events:none; } .frame i { position:absolute; width:26px; height:26px; border:2px solid var(--phosphor-dim); opacity:.5; } .frame .tl{top:0;left:0;border-right:0;border-bottom:0}.frame .tr{top:0;right:0;border-left:0;border-bottom:0}.frame .bl{bottom:0;left:0;border-right:0;border-top:0}.frame .br{bottom:0;right:0;border-left:0;border-top:0}
  .panel-fab,.panel-backdrop,.panel-close { display:none; }
  @media (max-width:720px) {
    .readout { display:none; }
    .dock-left { left:0; top:0; bottom:0; width:min(390px,92vw); z-index:900; transform:translateX(-102%); transition:transform .24s ease; pointer-events:auto; }
    .dock-left.open { transform:translateX(0); } .dock-left :global(.panel){width:100%;max-height:100%;border-radius:0;box-shadow:6px 0 24px rgba(0,0,0,.5)}
    .panel-backdrop { display:block; position:absolute; inset:0; z-index:850; margin:0; padding:0; border:0; background:rgba(3,8,7,.5); opacity:0; pointer-events:none; transition:opacity .24s ease; } .panel-backdrop.show{opacity:1;pointer-events:auto}
    .panel-fab { display:inline-flex; align-items:center; gap:7px; position:absolute; left:12px; bottom:14px; z-index:600; padding:11px 15px; font-family:var(--font-hud); letter-spacing:.14em; text-transform:uppercase; color:var(--phosphor-hot); background:rgba(8,19,17,.94); border:1px solid var(--edge-hot); border-radius:4px; } .panel-fab.hidden{display:none}
    .panel-close { display:flex; align-items:center; justify-content:center; position:absolute; top:8px; right:16px; z-index:20; width:36px; height:36px; padding:0; background:rgba(8,19,17,.9); border:1px solid var(--edge); color:var(--phosphor); }
  }
</style>
