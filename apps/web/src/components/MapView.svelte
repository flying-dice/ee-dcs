<script context="module" lang="ts">
  export type Mode = 'idle' | 'main-blue' | 'main-red' | 'edit';
</script>

<script lang="ts">
  import { onDestroy, onMount, createEventDispatcher } from 'svelte';
  import L from 'leaflet';
  import 'leaflet/dist/leaflet.css';
  import { airbaseId, candidateId } from '../lib/balance';
  import { territoryAt, roleFor } from '../lib/territory';
  import type { Terrain, CandidateKeysite, Keysite, KeysiteType, AirbasePoint, AdminBoundary, Side, LatLon, BBox } from '../lib/types';
  import type { TerritoryPlan } from '../lib/types';

  export let terrain: Terrain | null = null;
  export let activeBounds: BBox | null = null;
  export let keysites: Keysite[] = [];
  export let selectedIds: Set<string> = new Set();
  export let osm: CandidateKeysite[] = [];
  export let mainBlue: AirbasePoint | null = null;
  export let mainRed: AirbasePoint | null = null;
  export let mode: Mode = 'idle';
  export let adminBoundaries: AdminBoundary[] = [];
  export let adminBoundaryAssignments: Record<string, { side: Side; role: 'rear' | 'close' }> = {};
  export let territoryPlan: TerritoryPlan | null = null;
  export let focus: { id: string; n: number } | null = null;
  export let typeColors: Record<KeysiteType, string> = {} as Record<KeysiteType, string>;

  const dispatch = createEventDispatcher<{
    designateMain: AirbasePoint;
    toggleAirbase: AirbasePoint;
    toggleCandidate: CandidateKeysite;
    moveKeysite: { id: string; latlon: LatLon };
    openAdminBoundary: string;
  }>();

  const BLUE = '#4aa8ff';
  const RED = '#ff5157';
  const MAP_GREEN = '#0c7f4c';
  let mapEl: HTMLDivElement;
  let map: L.Map | undefined;
  let ro: ResizeObserver | undefined;
  let topRenderer: L.Renderer | undefined;
  let adminRenderer: L.SVG | undefined;
  let boundsLayer: L.Polygon | undefined;
  let activeBoundsLayer: L.Rectangle | undefined;
  const airbaseLayer = L.layerGroup();
  const osmLayer = L.layerGroup();
  const adminBoundaryLayer = L.layerGroup();
  const previewLayer = L.layerGroup();
  const keysiteEditLayer = L.layerGroup();
  const flashLayer = L.layerGroup();
  let lastFitId: string | null = null;
  let lastFocusN = 0;
  let flashTimer: ReturnType<typeof setTimeout> | undefined;

  function escapeHtml(value: string): string {
    return value.replace(/[&<>"']/g, (character) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character] ?? character));
  }
  function tooltip(title: string, sub: string): string {
    return `<b>${escapeHtml(title)}</b>${sub ? `<br><span class="tt-sub">${escapeHtml(sub)}</span>` : ''}`;
  }
  function boundaryLatLngs(coordinates: unknown): unknown {
    if (!Array.isArray(coordinates)) return [];
    if (coordinates.length >= 2 && typeof coordinates[0] === 'number' && typeof coordinates[1] === 'number') return [coordinates[1], coordinates[0]];
    return coordinates.map(boundaryLatLngs);
  }
  function territoryText(point: LatLon): string {
    if (!territoryPlan) return 'unassigned territory';
    const territory = territoryAt(territoryPlan, point);
    if (!territory) return 'outside selected territory';
    const role = roleFor(territoryPlan, point);
    return `${territory.owner.toUpperCase()} · ${role?.toUpperCase() ?? 'UNASSIGNED'}`;
  }
  function installHazardPatterns(): void {
    const svg = (adminRenderer as unknown as { _container?: SVGSVGElement } | undefined)?._container;
    if (!svg || svg.querySelector('[data-territory-hazards]')) return;
    const ns = 'http://www.w3.org/2000/svg';
    const defs = document.createElementNS(ns, 'defs');
    defs.dataset.territoryHazards = 'true';
    for (const [side, colour] of [['blue', BLUE], ['red', RED]] as const) {
      const pattern = document.createElementNS(ns, 'pattern');
      pattern.id = `territory-close-${side}`;
      pattern.setAttribute('width', '16');
      pattern.setAttribute('height', '16');
      pattern.setAttribute('patternUnits', 'userSpaceOnUse');
      pattern.setAttribute('patternTransform', 'rotate(45)');
      const base = document.createElementNS(ns, 'rect');
      base.setAttribute('width', '16');
      base.setAttribute('height', '16');
      base.setAttribute('fill', colour);
      const stripe = document.createElementNS(ns, 'rect');
      stripe.setAttribute('width', '7');
      stripe.setAttribute('height', '16');
      stripe.setAttribute('fill', '#04100d');
      stripe.setAttribute('fill-opacity', '0.72');
      pattern.append(base, stripe);
      defs.append(pattern);
    }
    svg.prepend(defs);
  }
  function drawTerrain(): void {
    if (!map) return;
    if (boundsLayer) { boundsLayer.remove(); boundsLayer = undefined; }
    if (activeBoundsLayer) { activeBoundsLayer.remove(); activeBoundsLayer = undefined; }
    if (!terrain) { map.setMinZoom(2); map.setMaxBounds(null as unknown as L.LatLngBounds); lastFitId = null; return; }
    const ring = terrain.boundsPolygon.map((point) => [point.lat, point.lon] as [number, number]);
    boundsLayer = L.polygon(ring, { color: MAP_GREEN, weight: 1.5, dashArray: '3 5', fillColor: MAP_GREEN, fillOpacity: 0.05, interactive: false }).addTo(map);
    if (terrain.id !== lastFitId) {
      lastFitId = terrain.id;
      const bounds = activeBounds
        ? L.latLngBounds([activeBounds.south, activeBounds.west], [activeBounds.north, activeBounds.east])
        : boundsLayer.getBounds();
      if (activeBounds) activeBoundsLayer = L.rectangle(bounds, { color: MAP_GREEN, weight: 2, dashArray: '8 6', fill: false, opacity: 0.75, interactive: false }).addTo(map);
      map.fitBounds(bounds, { padding: [20, 20] });
      const padded = bounds.pad(0.12);
      map.setMinZoom(map.getBoundsZoom(padded));
      map.setMaxBounds(padded);
    }
  }
  function drawAdminBoundaries(): void {
    adminBoundaryLayer.clearLayers();
    installHazardPatterns();
    for (const boundary of adminBoundaries) {
      const assignment = adminBoundaryAssignments[boundary.id];
      const colour = assignment?.side === 'blue' ? BLUE : assignment?.side === 'red' ? RED : MAP_GREEN;
      const state = assignment ? `${assignment.side.toUpperCase()} · ${assignment.role.toUpperCase()}` : 'OFF';
      const close = assignment?.role === 'close';
      const polygon = L.polygon(boundaryLatLngs(boundary.geometry.coordinates) as L.LatLngExpression[], {
        color: colour, weight: assignment ? 2.25 : 1, dashArray: close ? undefined : '6 4', opacity: assignment ? 0.9 : 0.38,
        fillColor: close ? `url(#territory-close-${assignment.side})` : colour,
        fillOpacity: assignment ? (close ? 0.48 : 0.1) : 0.015, interactive: mode === 'idle', renderer: adminRenderer,
      });
      polygon.bindTooltip(tooltip(boundary.name || boundary.id, `ADM${boundary.adminLevel} · ${state} · click to assign`), { sticky: true, opacity: 0.95 });
      polygon.on('click', (event) => { if (mode === 'idle') { L.DomEvent.stop(event.originalEvent); dispatch('openAdminBoundary', boundary.id); } });
      polygon.addTo(adminBoundaryLayer);
    }
  }
  function drawAirbases(): void {
    airbaseLayer.clearLayers();
    if (!terrain) return;
    for (const ab of terrain.airbases) {
      const id = airbaseId(ab);
      const isBlueMain = mainBlue?.name === ab.name;
      const isRedMain = mainRed?.name === ab.name;
      const selected = selectedIds.has(id);
      const owner = territoryPlan ? territoryAt(territoryPlan, ab.latlon)?.owner : undefined;
      const colour = isBlueMain ? BLUE : isRedMain ? RED : owner === 'blue' ? BLUE : owner === 'red' ? RED : MAP_GREEN;
      const role = isBlueMain ? 'BLUE main' : isRedMain ? 'RED main' : selected ? 'airbase (selected)' : territoryText(ab.latlon);
      const marker = L.circleMarker([ab.latlon.lat, ab.latlon.lon], {
        radius: isBlueMain || isRedMain ? 9 : selected ? 7 : owner ? 6 : 5,
        weight: isBlueMain || isRedMain ? 4 : selected ? 3 : owner ? 2.5 : 1.75,
        color: colour, fill: isBlueMain || isRedMain || selected || !!owner, fillColor: colour,
        fillOpacity: isBlueMain || isRedMain ? 0.52 : owner ? 0.22 : 0.1, interactive: true, renderer: topRenderer,
      });
      marker.bindTooltip(tooltip(ab.name, `${role} · ${ab.category}`), { direction: 'top', opacity: 0.95 });
      marker.on('click', (event) => {
        if (mode === 'main-blue' || mode === 'main-red') { L.DomEvent.stop(event.originalEvent); dispatch('designateMain', ab); }
        else if (mode === 'edit') { L.DomEvent.stop(event.originalEvent); dispatch('toggleAirbase', ab); }
      });
      marker.addTo(airbaseLayer);
      L.marker([ab.latlon.lat, ab.latlon.lon], { interactive: false, icon: L.divIcon({ className: 'ab-label', html: escapeHtml(ab.name), iconSize: [0, 0], iconAnchor: [-10, 6] }) }).addTo(airbaseLayer);
    }
  }
  function drawOsm(): void {
    osmLayer.clearLayers();
    for (const candidate of osm) {
      if (candidate.type === 'airbase') continue;
      const id = candidateId(candidate);
      const selected = selectedIds.has(id);
      if (!selected && mode !== 'edit') continue;
      const owner = territoryPlan ? territoryAt(territoryPlan, candidate.latlon)?.owner : undefined;
      const marker = L.circleMarker([candidate.latlon.lat, candidate.latlon.lon], {
        radius: selected ? 6 : 3, weight: selected ? 2 : 1, color: selected ? '#ffffff' : typeColors[candidate.type],
        fillColor: selected ? (owner === 'blue' ? BLUE : RED) : typeColors[candidate.type], fillOpacity: selected ? 1 : 0.25,
        interactive: mode === 'edit', renderer: topRenderer,
      });
      marker.bindTooltip(tooltip(candidate.name || candidate.type, `${selected ? 'selected · ' : ''}${candidate.type} · ${territoryText(candidate.latlon)}`), { direction: 'top', opacity: 0.95 });
      marker.on('click', (event) => { if (mode === 'edit') { L.DomEvent.stop(event.originalEvent); dispatch('toggleCandidate', candidate); } });
      marker.addTo(osmLayer);
    }
  }
  function drawPreview(): void {
    previewLayer.clearLayers();
    for (const keysite of keysites) L.circle([keysite.latlon.lat, keysite.latlon.lon], {
      radius: keysite.radiusM, color: keysite.side === 'blue' ? BLUE : RED, weight: 2.5, opacity: 0.9,
      fillColor: keysite.side === 'blue' ? BLUE : RED, fillOpacity: keysite.type === 'airbase' ? 0.14 : 0.2, interactive: false,
    }).addTo(previewLayer);
  }
  function drawKeysiteHandles(): void {
    keysiteEditLayer.clearLayers();
    if (mode !== 'edit') return;
    for (const keysite of keysites) {
      if (keysite.locationTied) continue;
      const colour = keysite.side === 'blue' ? BLUE : RED;
      const marker = L.marker([keysite.latlon.lat, keysite.latlon.lon], { draggable: true, pane: 'top', icon: L.divIcon({ className: 'ks-move-h', html: `<span style="border-color:${colour}">✥</span>`, iconSize: [24, 24], iconAnchor: [12, 12] }) });
      marker.bindTooltip(tooltip(keysite.name, `drag to move · ${keysite.type}`), { direction: 'top', opacity: 0.95 });
      marker.on('dragend', () => { const point = marker.getLatLng(); dispatch('moveKeysite', { id: keysite.id, latlon: { lat: point.lat, lon: point.lng } }); });
      marker.addTo(keysiteEditLayer);
    }
  }
  function applyFocus(): void {
    if (!map || !focus || focus.n === lastFocusN) return;
    lastFocusN = focus.n;
    const keysite = keysites.find((entry) => entry.id === focus?.id);
    if (!keysite) return;
    const point: [number, number] = [keysite.latlon.lat, keysite.latlon.lon];
    map.setView(point, Math.max(map.getZoom(), 9), { animate: true });
    flashLayer.clearLayers();
    L.circleMarker(point, { radius: 14, color: '#ffffff', weight: 2, fill: false, interactive: false }).addTo(flashLayer);
    if (flashTimer) clearTimeout(flashTimer);
    flashTimer = setTimeout(() => flashLayer.clearLayers(), 1700);
  }
  $: if (map) { terrain; activeBounds; drawTerrain(); }
  $: if (map) { adminBoundaries; adminBoundaryAssignments; territoryPlan; mode; drawAdminBoundaries(); }
  $: if (map) { terrain; mainBlue; mainRed; selectedIds; territoryPlan; mode; drawAirbases(); }
  $: if (map) { osm; selectedIds; territoryPlan; mode; drawOsm(); }
  $: if (map) { keysites; drawPreview(); }
  $: if (map) { keysites; mode; drawKeysiteHandles(); }
  $: if (map) { focus; applyFocus(); }
  $: if (map) { mode; if (map) map.getContainer().style.cursor = mode === 'idle' ? '' : 'pointer'; }
  onMount(() => {
    map = L.map(mapEl, { zoomControl: false, preferCanvas: true, maxBoundsViscosity: 1, minZoom: 2 }).setView([43, 42], 6);
    L.control.zoom({ position: 'bottomright' }).addTo(map);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 18, attribution: '© OpenStreetMap contributors' }).addTo(map);
    map.createPane('admin-territory'); const adminPane = map.getPane('admin-territory'); if (adminPane) adminPane.style.zIndex = '410';
    adminRenderer = L.svg({ pane: 'admin-territory' }).addTo(map);
    installHazardPatterns();
    map.createPane('top'); const top = map.getPane('top'); if (top) top.style.zIndex = '640'; topRenderer = L.svg({ pane: 'top' });
    map.createPane('flash'); const flash = map.getPane('flash'); if (flash) { flash.style.zIndex = '690'; flash.style.pointerEvents = 'none'; }
    adminBoundaryLayer.addTo(map); previewLayer.addTo(map); osmLayer.addTo(map); airbaseLayer.addTo(map); flashLayer.addTo(map); keysiteEditLayer.addTo(map);
    drawTerrain(); drawAdminBoundaries(); drawAirbases(); drawOsm(); drawPreview(); drawKeysiteHandles();
    ro = new ResizeObserver(() => map?.invalidateSize()); ro.observe(mapEl);
  });
  onDestroy(() => { ro?.disconnect(); if (flashTimer) clearTimeout(flashTimer); if (map) { map.off(); map.remove(); map = undefined; } });
</script>

<div class="map" bind:this={mapEl}></div>

<style>
  .map { width: 100%; height: 100%; }
  :global(.leaflet-container) { background: var(--void); font-family: var(--font-ui); }
  :global(.leaflet-interactive:focus) { outline: none; }
  :global(.leaflet-tile) { filter: saturate(0.62) brightness(0.78) contrast(1.06); }
  :global(.leaflet-bar) { border: none; box-shadow: 0 4px 16px rgba(0,0,0,.5); }
  :global(.leaflet-bar a) { background: rgba(8,19,17,.92); color: var(--phosphor); border-color: var(--edge) !important; }
  :global(.leaflet-control-attribution) { background: rgba(4,16,12,.76) !important; color: var(--muted) !important; font-size: 10px; }
  :global(.leaflet-tooltip) { background: rgba(4,16,12,.95); color: var(--ink); border: 1px solid var(--edge-hot); border-radius: 2px; box-shadow: 0 3px 12px rgba(0,0,0,.5); padding: 5px 7px; font-size: 11px; }
  :global(.leaflet-tooltip b) { color: var(--phosphor-hot); font-family: var(--font-hud); }
  :global(.tt-sub) { color: var(--muted); }
  :global(.ab-label) { color: #d9fce9; font: 10px/1 var(--font-hud); text-shadow: 0 1px 3px #000, 0 0 3px #000; white-space: nowrap; pointer-events: none; }
  :global(.ks-move-h span) { display: grid; width: 20px; height: 20px; place-items: center; border: 2px solid; color: #fff; background: rgba(4,16,12,.88); border-radius: 50%; cursor: grab; }
</style>
