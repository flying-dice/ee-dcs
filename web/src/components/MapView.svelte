<script context="module" lang="ts">
  // Interaction mode, shared with App + ControlPanel (module scope = importable).
  export type Mode = 'idle' | 'bbox' | 'bbox-edit' | 'frontline' | 'frontline-edit' | 'main-blue' | 'main-red' | 'edit';
</script>

<script lang="ts">
  // ── MapView: the Leaflet canvas + all drawing interactions ─────────────────────
  // Driven declaratively by props; pushes gestures back up as events. VECTOR LAYERS
  // ONLY. Clickable markers (airbase rings + OSM dots) render on a dedicated SVG pane
  // ABOVE the canvas so overlays never swallow their clicks.
  import { onMount, onDestroy, createEventDispatcher } from 'svelte';
  import L from 'leaflet';
  import 'leaflet/dist/leaflet.css';
  import { sideOfFrontline, airbaseId, candidateId } from '../lib/balance';
  import type {
    Terrain, BBox, LatLon, CandidateKeysite, Keysite, KeysiteType, AirbasePoint,
  } from '../lib/types';

  // ── props ──────────────────────────────────────────────────────────────────────
  export let terrain: Terrain | null = null;
  export let bbox: BBox | null = null;
  export let bboxValid = false;
  export let frontline: LatLon[] = [];
  export let frontlineComplete = false;
  export let blueSign = 1;
  export let keysites: Keysite[] = [];
  export let selectedIds: Set<string> = new Set();
  export let osm: CandidateKeysite[] = [];
  export let mainBlue: AirbasePoint | null = null;
  export let mainRed: AirbasePoint | null = null;
  export let mode: Mode = 'idle';
  /** Focus request from the list (id + bump counter) → pan to + flash the keysite. */
  export let focus: { id: string; n: number } | null = null;
  export let typeColors: Record<KeysiteType, string> = {} as Record<KeysiteType, string>;

  const dispatch = createEventDispatcher<{
    bbox: BBox;
    bboxEdit: BBox;
    frontlinePoint: LatLon;
    frontlineFinish: void;
    frontlineEdit: LatLon[];
    designateMain: AirbasePoint;
    toggleAirbase: AirbasePoint;
    toggleCandidate: CandidateKeysite;
  }>();

  const BLUE = '#4aa8ff';
  const RED = '#ff5157';
  const PHOSPHOR = '#5cf2a6';
  // Deeper green for strokes drawn over the light OSM basemap — the bright phosphor
  // washes out on light tiles, so on-map green (terrain bounds, unselected rings) uses this.
  const MAP_GREEN = '#0c7f4c';
  const AMBER = '#f6a623';
  const HULL = '#04100c';

  let mapEl: HTMLDivElement;
  let map: L.Map | undefined;
  let ro: ResizeObserver | undefined;

  // SVG renderer on a top pane so airbase rings + OSM dots always receive clicks.
  let topRenderer: L.Renderer | undefined;

  let boundsLayer: L.Polygon | undefined;
  let bboxLayer: L.Rectangle | undefined;
  const airbaseLayer = L.layerGroup();
  const osmLayer = L.layerGroup();
  const frontLayer = L.layerGroup();
  const mainLayer = L.layerGroup();
  const previewLayer = L.layerGroup();
  const flashLayer = L.layerGroup();

  let activeMode: Mode = 'idle';
  let lastFitId: string | null = null;
  let rubber: L.Rectangle | undefined;
  let dragStart: L.LatLng | undefined;
  let lastFocusN = 0;
  let flashTimer: ReturnType<typeof setTimeout> | undefined;

  // Gesture modes need the map surface free of interactive markers.
  $: gestureMode = mode === 'bbox' || mode === 'frontline';

  function sideColor(p: LatLon): string {
    return sideOfFrontline(p, frontline) === blueSign ? BLUE : RED;
  }

  function escapeHtml(s: string): string {
    return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]!));
  }

  // A short "key=value · key=value" line from the underlying tags for the tooltip.
  const INFO_KEYS = [
    'category', 'operator', 'aeroway', 'military', 'man_made', 'landuse',
    'industrial', 'power', 'harbour', 'role',
  ];
  function tagInfo(tags?: Record<string, string>): string {
    if (!tags) return '';
    const parts: string[] = [];
    for (const k of INFO_KEYS) {
      if (tags[k]) parts.push(`${k}=${escapeHtml(tags[k])}`);
      if (parts.length >= 3) break;
    }
    return parts.join(' · ');
  }
  function tooltip(title: string, sub: string, info: string): string {
    return (
      `<b>${escapeHtml(title)}</b>` +
      (sub ? `<br><span class="tt-sub">${escapeHtml(sub)}</span>` : '') +
      (info ? `<br><span class="tt-info">${info}</span>` : '')
    );
  }

  // ── draw functions ───────────────────────────────────────────────────────────
  function drawTerrain(): void {
    if (!map) return;
    if (boundsLayer) { boundsLayer.remove(); boundsLayer = undefined; }
    if (!terrain) {
      // No theatre: free the map to roam the whole world again.
      map.setMinZoom(2);
      map.setMaxBounds(null as unknown as L.LatLngBounds);
      lastFitId = null;
      return;
    }
    const ring = terrain.boundsPolygon.map((p) => [p.lat, p.lon] as [number, number]);
    boundsLayer = L.polygon(ring, {
      color: MAP_GREEN, weight: 1.5, dashArray: '3 5', fillColor: MAP_GREEN, fillOpacity: 0.05, interactive: false,
    }).addTo(map);
    if (terrain.id !== lastFitId) {
      lastFitId = terrain.id;
      const b = boundsLayer.getBounds();
      map.fitBounds(b, { padding: [20, 20] });
      // Lock the view to the theatre box — you can't pan or zoom out to the whole world.
      const padded = b.pad(0.12);
      map.setMinZoom(map.getBoundsZoom(padded));
      map.setMaxBounds(padded);
    }
  }

  // Scraped DCS airbases — hollow rings, clickable to set mains / toggle membership.
  function drawAirbases(): void {
    airbaseLayer.clearLayers();
    if (!terrain) return;
    const interactive = !gestureMode; // free the surface while drawing bbox/frontline
    for (const ab of terrain.airbases) {
      const ll: [number, number] = [ab.latlon.lat, ab.latlon.lon];
      const id = airbaseId(ab);
      const isMB = !!mainBlue && ab.name === mainBlue.name;
      const isMR = !!mainRed && ab.name === mainRed.name;
      const selected = selectedIds.has(id);

      let color = MAP_GREEN, weight = 1.75, radius = 5, ringOpacity = 0.95;
      let role = 'DCS airfield';
      if (isMB) { color = BLUE; weight = 3; radius = 8; ringOpacity = 1; role = 'BLUE main'; }
      else if (isMR) { color = RED; weight = 3; radius = 8; ringOpacity = 1; role = 'RED main'; }
      else if (selected) { color = sideColor(ab.latlon); weight = 3; radius = 7; ringOpacity = 1; role = 'airbase (selected)'; }

      // Selected airbases get a soft halo so they read clearly over the dimmed rest.
      if (isMB || isMR || selected) {
        L.circleMarker(ll, {
          radius: radius + 5, weight: 1.5, color, opacity: 0.55, fill: false,
          interactive: false, renderer: topRenderer,
        }).addTo(airbaseLayer);
      }

      const ring = L.circleMarker(ll, {
        radius, weight, color, opacity: ringOpacity,
        fill: !!(isMB || isMR || selected),
        fillColor: color, fillOpacity: isMB || isMR ? 0.3 : selected ? 0.22 : 0,
        interactive, renderer: topRenderer,
      });
      ring.bindTooltip(tooltip(ab.name, role, `category=${escapeHtml(ab.category)}`), { direction: 'top', opacity: 0.95 });
      ring.on('click', (e) => {
        if (mode === 'main-blue' || mode === 'main-red') {
          L.DomEvent.stop(e.originalEvent);
          dispatch('designateMain', ab);
        } else if (mode === 'edit') {
          L.DomEvent.stop(e.originalEvent);
          dispatch('toggleAirbase', ab);
        }
      });
      ring.addTo(airbaseLayer);

      // center dot + name label (non-interactive)
      L.circleMarker(ll, { radius: 1.5, weight: 0, fillColor: color, fillOpacity: 1, interactive: false }).addTo(airbaseLayer);
      L.marker(ll, {
        interactive: false,
        icon: L.divIcon({ className: 'ab-label', html: escapeHtml(ab.name), iconSize: [0, 0], iconAnchor: [-10, 6] }),
      }).addTo(airbaseLayer);
      if (isMB || isMR) {
        L.marker(ll, {
          interactive: false,
          icon: L.divIcon({ className: 'main-star', html: `<span style="color:${color}">★</span>`, iconSize: [16, 16], iconAnchor: [8, 8] }),
        }).addTo(airbaseLayer);
      }
    }
  }

  function drawBbox(): void {
    if (!map) return;
    if (bboxLayer) { bboxLayer.remove(); bboxLayer = undefined; }
    if (!bbox) return;
    const color = bboxValid ? PHOSPHOR : RED;
    bboxLayer = L.rectangle(
      [[bbox.south, bbox.west], [bbox.north, bbox.east]],
      { color, weight: 2, fillOpacity: 0.04, interactive: false },
    ).addTo(map);
  }

  // OSM candidate dots — dim/hollow when unpicked, side-filled when selected. Clickable
  // to toggle membership in edit mode; always hover-tooltipped for the underlying data.
  function drawOsm(): void {
    osmLayer.clearLayers();
    const interactive = !gestureMode;
    for (const c of osm) {
      if (c.type === 'airbase') continue; // airbases come from the DCS ring layer
      const id = candidateId(c);
      const selected = selectedIds.has(id);
      const ll: [number, number] = [c.latlon.lat, c.latlon.lon];

      // Selected sites read as bold side-coloured dots with a halo; unselected
      // candidates stay small and dim so the active network stands out.
      if (selected) {
        const col = sideColor(c.latlon);
        L.circleMarker(ll, {
          radius: 9, weight: 1.5, color: col, opacity: 0.55, fill: false,
          interactive: false, renderer: topRenderer,
        }).addTo(osmLayer);
      }
      const m = L.circleMarker(ll, {
        radius: selected ? 6 : 3,
        weight: selected ? 2 : 1,
        color: selected ? '#ffffff' : typeColors[c.type],
        opacity: selected ? 1 : 0.6,
        fillColor: selected ? sideColor(c.latlon) : typeColors[c.type],
        fillOpacity: selected ? 1 : 0.25,
        interactive,
        renderer: topRenderer,
      });
      m.bindTooltip(tooltip(c.name || c.type, `${selected ? 'selected · ' : ''}${c.type}`, tagInfo(c.source.tags)), {
        direction: 'top', opacity: 0.95,
      });
      m.on('click', (e) => {
        if (mode === 'edit') {
          L.DomEvent.stop(e.originalEvent);
          dispatch('toggleCandidate', c);
        }
      });
      osmLayer.addLayer(m);
    }
  }

  function drawFrontline(): void {
    frontLayer.clearLayers();
    if (frontline.length === 0) return;
    if (frontline.length >= 2) {
      L.polyline(frontline.map((p) => [p.lat, p.lon] as [number, number]), {
        color: AMBER, weight: 3, dashArray: '9 7', interactive: false,
      }).addTo(frontLayer);
    }
    // In edit mode the draggable handles stand in for the vertices, so skip the dots.
    if (mode === 'frontline-edit') return;
    for (const p of frontline) {
      L.circleMarker([p.lat, p.lon], {
        radius: 4, weight: 2, color: AMBER, fillColor: HULL, fillOpacity: 1, interactive: false,
      }).addTo(frontLayer);
    }
  }

  // Selected keysite zones — side-coloured circles at real zone radius. Non-interactive
  // so clicks fall through to the rings/dots on the top pane above.
  function drawPreview(): void {
    previewLayer.clearLayers();
    for (const k of keysites) {
      const colour = k.side === 'blue' ? BLUE : RED;
      L.circle([k.latlon.lat, k.latlon.lon], {
        radius: k.radiusM, color: colour, weight: 2.5, opacity: 0.9, fillColor: colour,
        fillOpacity: k.type === 'airbase' ? 0.14 : 0.2, interactive: false,
      }).addTo(previewLayer);
    }
  }

  // Pan to a keysite and flash a pulse ring over it (list-row click).
  function applyFocus(): void {
    if (!map || !focus || focus.n === lastFocusN) return;
    lastFocusN = focus.n;
    const k = keysites.find((x) => x.id === focus!.id);
    if (!k) return;
    const ll: [number, number] = [k.latlon.lat, k.latlon.lon];
    map.setView(ll, Math.max(map.getZoom(), 9), { animate: true });
    flashLayer.clearLayers();
    L.marker(ll, {
      interactive: false,
      pane: 'flash',
      icon: L.divIcon({ className: 'ks-flash', html: '<b></b>', iconSize: [0, 0] }),
    }).addTo(flashLayer);
    if (flashTimer) clearTimeout(flashTimer);
    flashTimer = setTimeout(() => flashLayer.clearLayers(), 1700);
  }

  function applyMode(): void {
    activeMode = mode;
    if (!map) return;
    if (mode === 'bbox') map.dragging.disable();
    else map.dragging.enable();
    if (mode === 'frontline') map.doubleClickZoom.disable();
    else map.doubleClickZoom.enable();
    const cursor =
      mode === 'bbox' ? 'crosshair' : mode === 'frontline' ? 'copy'
      : mode === 'bbox-edit' || mode === 'frontline-edit' ? 'move'
      : mode === 'main-blue' || mode === 'main-red' || mode === 'edit' ? 'pointer' : '';
    map.getContainer().style.cursor = cursor;
  }

  // ── reactive redraws ─────────────────────────────────────────────────────────
  $: if (map) { terrain; drawTerrain(); }
  $: if (map) { terrain; mode; selectedIds; mainBlue; mainRed; frontline; blueSign; drawAirbases(); }
  $: if (map) { bbox; bboxValid; drawBbox(); }
  $: if (map) { osm; selectedIds; mode; frontline; blueSign; drawOsm(); }
  $: if (map) { frontline; frontlineComplete; mode; drawFrontline(); }
  $: if (map) { keysites; drawPreview(); }
  $: if (map) { mode; applyMode(); }
  $: if (map) { focus; applyFocus(); }
  $: if (map) { mode; bbox; syncBboxEdit(); }
  $: if (map) { mode; frontline; syncFrontlineEdit(); }

  // ── gesture handlers ───────────────────────────────────────────────────────────
  function onMouseDown(e: L.LeafletMouseEvent): void {
    if (activeMode !== 'bbox' || !map) return;
    dragStart = e.latlng;
    rubber = L.rectangle(L.latLngBounds(e.latlng, e.latlng), {
      color: PHOSPHOR, weight: 1.5, dashArray: '4 4', fillOpacity: 0.05, interactive: false,
    }).addTo(map);
  }
  function onMouseMove(e: L.LeafletMouseEvent): void {
    if (activeMode !== 'bbox' || !rubber || !dragStart) return;
    rubber.setBounds(L.latLngBounds(dragStart, e.latlng));
  }
  function onMouseUp(e: L.LeafletMouseEvent): void {
    if (activeMode !== 'bbox' || !dragStart) return;
    const b = L.latLngBounds(dragStart, e.latlng);
    if (rubber) { rubber.remove(); rubber = undefined; }
    dragStart = undefined;
    const north = b.getNorth(), south = b.getSouth(), east = b.getEast(), west = b.getWest();
    if (north - south < 1e-4 || east - west < 1e-4) return;
    dispatch('bbox', { north, south, east, west });
  }
  function onClick(e: L.LeafletMouseEvent): void {
    if (activeMode !== 'frontline') return;
    dispatch('frontlinePoint', { lat: e.latlng.lat, lon: e.latlng.lng });
  }
  function onDblClick(): void {
    if (activeMode !== 'frontline') return;
    dispatch('frontlineFinish');
  }

  // ── touch: single-finger bbox draw (Leaflet fires no mouse events on touch) ──────
  function touchLatLng(t: Touch): L.LatLng | undefined {
    if (!map) return undefined;
    const rect = map.getContainer().getBoundingClientRect();
    return map.containerPointToLatLng(L.point(t.clientX - rect.left, t.clientY - rect.top));
  }
  function onTouchStart(e: TouchEvent): void {
    if (activeMode !== 'bbox' || !map || e.touches.length !== 1) return;
    const ll = touchLatLng(e.touches[0]);
    if (!ll) return;
    e.preventDefault(); // suppress page scroll / map pan while drawing
    dragStart = ll;
    rubber = L.rectangle(L.latLngBounds(ll, ll), {
      color: PHOSPHOR, weight: 1.5, dashArray: '4 4', fillOpacity: 0.05, interactive: false,
    }).addTo(map);
  }
  function onTouchMove(e: TouchEvent): void {
    if (activeMode !== 'bbox' || !rubber || !dragStart || e.touches.length !== 1) return;
    const ll = touchLatLng(e.touches[0]);
    if (!ll) return;
    e.preventDefault();
    rubber.setBounds(L.latLngBounds(dragStart, ll));
  }
  function onTouchEnd(e: TouchEvent): void {
    if (activeMode !== 'bbox' || !dragStart) return;
    const t = e.changedTouches[0];
    const end = t ? touchLatLng(t) : undefined;
    if (rubber) { rubber.remove(); rubber = undefined; }
    const start = dragStart;
    dragStart = undefined;
    if (!end) return;
    const b = L.latLngBounds(start, end);
    const north = b.getNorth(), south = b.getSouth(), east = b.getEast(), west = b.getWest();
    if (north - south < 1e-4 || east - west < 1e-4) return;
    dispatch('bbox', { north, south, east, west });
  }

  // ── editable bbox: drag corners/edges to resize, the centre pip to move ──────────
  const bboxEditLayer = L.layerGroup();
  let bboxHandles: { role: HRole; marker: L.Marker }[] = [];
  let handlesBuilt = false;
  let editBox: BBox | null = null;

  type HRole = 'nw' | 'n' | 'ne' | 'e' | 'se' | 's' | 'sw' | 'w' | 'move';
  const H_ROLES: HRole[] = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w', 'move'];

  function handleLatLng(role: HRole, b: BBox): [number, number] {
    const midLat = (b.north + b.south) / 2;
    const midLon = (b.east + b.west) / 2;
    switch (role) {
      case 'nw': return [b.north, b.west];
      case 'n': return [b.north, midLon];
      case 'ne': return [b.north, b.east];
      case 'e': return [midLat, b.east];
      case 'se': return [b.south, b.east];
      case 's': return [b.south, midLon];
      case 'sw': return [b.south, b.west];
      case 'w': return [midLat, b.west];
      default: return [midLat, midLon];
    }
  }

  function buildBboxHandles(): void {
    bboxEditLayer.clearLayers();
    bboxHandles = [];
    if (!map || !editBox) return;
    for (const role of H_ROLES) {
      const kind = role === 'move' ? 'move' : role.length === 2 ? 'corner' : 'edge';
      const size = role === 'move' ? 22 : 14;
      const marker = L.marker(handleLatLng(role, editBox), {
        draggable: true,
        pane: 'top',
        icon: L.divIcon({
          className: `bbox-h ${kind}`,
          html: role === 'move' ? '✥' : '',
          iconSize: [size, size],
          iconAnchor: [size / 2, size / 2],
        }),
      });
      marker.on('drag', () => onHandleDrag(role, marker));
      marker.on('dragend', () => { if (editBox) repositionHandles(editBox); });
      marker.addTo(bboxEditLayer);
      bboxHandles.push({ role, marker });
    }
  }

  function repositionHandles(b: BBox): void {
    for (const h of bboxHandles) h.marker.setLatLng(handleLatLng(h.role, b));
  }

  function onHandleDrag(role: HRole, marker: L.Marker): void {
    if (!editBox) return;
    const p = marker.getLatLng();
    let { north, south, east, west } = editBox;
    if (role === 'move') {
      const dLat = p.lat - (north + south) / 2;
      const dLon = p.lng - (east + west) / 2;
      north += dLat; south += dLat; east += dLon; west += dLon;
    } else {
      if (role.includes('n')) north = p.lat;
      if (role.includes('s')) south = p.lat;
      if (role.includes('e')) east = p.lng;
      if (role.includes('w')) west = p.lng;
    }
    editBox = {
      north: Math.max(north, south), south: Math.min(north, south),
      east: Math.max(east, west), west: Math.min(east, west),
    };
    // Move the sibling handles live (not the one under the cursor) and push the box up.
    for (const h of bboxHandles) if (h.marker !== marker) h.marker.setLatLng(handleLatLng(h.role, editBox));
    dispatch('bboxEdit', editBox);
  }

  // Build handles when entering bbox-edit; tear them down when leaving. The guard flag
  // keeps live bbox updates (my own drags) from recreating handles mid-drag.
  function syncBboxEdit(): void {
    const should = mode === 'bbox-edit' && !!bbox;
    if (should && !handlesBuilt) {
      editBox = { ...(bbox as BBox) };
      buildBboxHandles();
      handlesBuilt = true;
    } else if (!should && handlesBuilt) {
      bboxEditLayer.clearLayers();
      bboxHandles = [];
      handlesBuilt = false;
      editBox = null;
    }
  }

  // ── editable frontline: drag vertices, drag a segment midpoint to insert one ──────
  const flEditLayer = L.layerGroup();
  let flHandles: L.Marker[] = [];
  let flHandlesBuilt = false;
  let flEditLine: LatLon[] | null = null;

  function emitFl(): void {
    if (flEditLine) dispatch('frontlineEdit', flEditLine.map((p) => ({ ...p })));
  }
  function flMarker(ll: LatLon, kind: 'vertex' | 'mid'): L.Marker {
    const size = kind === 'vertex' ? 15 : 11;
    return L.marker([ll.lat, ll.lon], {
      draggable: true,
      pane: 'top',
      icon: L.divIcon({ className: `fl-h ${kind}`, iconSize: [size, size], iconAnchor: [size / 2, size / 2] }),
    });
  }
  function buildFrontlineHandles(): void {
    flEditLayer.clearLayers();
    flHandles = [];
    if (!map || !flEditLine || flEditLine.length < 2) return;
    // Vertex handles.
    flEditLine.forEach((p, i) => {
      const m = flMarker(p, 'vertex');
      m.on('drag', () => onVertexDrag(i, m));
      m.on('dragend', () => { if (flEditLine) buildFrontlineHandles(); });
      m.addTo(flEditLayer);
      flHandles.push(m);
    });
    // Midpoint handles — drag one to split its segment (insert a new vertex there).
    for (let i = 0; i < flEditLine.length - 1; i++) {
      const a = flEditLine[i];
      const b = flEditLine[i + 1];
      const m = flMarker({ lat: (a.lat + b.lat) / 2, lon: (a.lon + b.lon) / 2 }, 'mid');
      m.on('dragstart', () => onMidStart(i, m));
      m.on('drag', () => onMidDrag(i, m));
      m.on('dragend', () => { if (flEditLine) buildFrontlineHandles(); });
      m.addTo(flEditLayer);
      flHandles.push(m);
    }
  }
  function onVertexDrag(i: number, m: L.Marker): void {
    if (!flEditLine) return;
    const ll = m.getLatLng();
    flEditLine[i] = { lat: ll.lat, lon: ll.lng };
    emitFl();
  }
  function onMidStart(i: number, m: L.Marker): void {
    if (!flEditLine) return;
    const ll = m.getLatLng();
    flEditLine.splice(i + 1, 0, { lat: ll.lat, lon: ll.lng }); // the mid becomes a real vertex
    emitFl();
  }
  function onMidDrag(i: number, m: L.Marker): void {
    if (!flEditLine) return;
    const ll = m.getLatLng();
    flEditLine[i + 1] = { lat: ll.lat, lon: ll.lng };
    emitFl();
  }
  function syncFrontlineEdit(): void {
    const should = mode === 'frontline-edit' && frontline.length >= 2;
    if (should && !flHandlesBuilt) {
      flEditLine = frontline.map((p) => ({ ...p }));
      buildFrontlineHandles();
      flHandlesBuilt = true;
    } else if (!should && flHandlesBuilt) {
      flEditLayer.clearLayers();
      flHandles = [];
      flHandlesBuilt = false;
      flEditLine = null;
    }
  }

  onMount(() => {
    map = L.map(mapEl, { zoomControl: false, preferCanvas: true, maxBoundsViscosity: 1.0, minZoom: 2 }).setView([43, 42], 6);
    L.control.zoom({ position: 'bottomright' }).addTo(map);
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 18, attribution: '© OpenStreetMap contributors',
    }).addTo(map);

    // Top pane + SVG renderer for the clickable markers, above the canvas overlays.
    map.createPane('top');
    const tp = map.getPane('top');
    if (tp) tp.style.zIndex = '640';
    topRenderer = L.svg({ pane: 'top' });

    // Flash pane sits above everything (incl. tooltips) for the locate pulse.
    map.createPane('flash');
    const fp = map.getPane('flash');
    if (fp) { fp.style.zIndex = '690'; fp.style.pointerEvents = 'none'; }

    // Draw order (canvas): bounds < bbox < preview < frontline. Rings/dots are on the SVG top pane.
    previewLayer.addTo(map);
    frontLayer.addTo(map);
    osmLayer.addTo(map);
    airbaseLayer.addTo(map);
    mainLayer.addTo(map);
    flashLayer.addTo(map);
    bboxEditLayer.addTo(map);
    flEditLayer.addTo(map);

    map.on('mousedown', onMouseDown);
    map.on('mousemove', onMouseMove);
    map.on('mouseup', onMouseUp);
    map.on('click', onClick);
    map.on('dblclick', onDblClick);

    // Touch equivalents for the bbox rubber-band (mouse events don't fire on touch).
    mapEl.addEventListener('touchstart', onTouchStart, { passive: false });
    mapEl.addEventListener('touchmove', onTouchMove, { passive: false });
    mapEl.addEventListener('touchend', onTouchEnd);

    drawTerrain();
    drawAirbases();
    drawBbox();
    drawOsm();
    drawFrontline();
    drawPreview();
    applyMode();

    ro = new ResizeObserver(() => map?.invalidateSize());
    ro.observe(mapEl);
  });

  onDestroy(() => {
    ro?.disconnect();
    if (flashTimer) clearTimeout(flashTimer);
    if (map) { map.off(); map.remove(); map = undefined; }
  });
</script>

<div class="map" bind:this={mapEl}></div>

<style>
  .map { width: 100%; height: 100%; }
  :global(.leaflet-container) { background: var(--void); font-family: var(--font-ui); }
  :global(.leaflet-tile) { filter: saturate(0.62) brightness(0.78) contrast(1.06); }

  :global(.leaflet-bar) { border: none; box-shadow: 0 4px 16px rgba(0, 0, 0, 0.5); }
  :global(.leaflet-bar a) {
    background: rgba(8, 19, 17, 0.92);
    color: var(--phosphor);
    border-bottom: 1px solid var(--edge);
    font-family: var(--font-hud);
  }
  :global(.leaflet-bar a:hover) { background: var(--panel-2); color: var(--phosphor-hot); }

  :global(.leaflet-control-attribution) {
    background: rgba(6, 15, 13, 0.82) !important;
    color: var(--ink-dim) !important;
    font-size: 10px;
    padding: 1px 6px;
  }
  :global(.leaflet-control-attribution a) { color: var(--phosphor-dim) !important; }

  :global(.main-star) {
    font-size: 15px;
    line-height: 16px;
    text-align: center;
    text-shadow: 0 0 4px #000, 0 0 8px currentColor;
    font-weight: bold;
  }
  :global(.ab-label) {
    font-family: var(--font-hud);
    font-size: 10px;
    letter-spacing: 0.06em;
    color: #baffdb;
    white-space: nowrap;
    /* dark chip so the name reads over the light basemap */
    background: rgba(4, 14, 11, 0.72);
    padding: 1px 4px;
    border-radius: 2px;
    pointer-events: none;
  }
  /* editable-bbox drag handles */
  :global(.bbox-h) {
    box-sizing: border-box;
    border: 2px solid #7dffbe;
    background: rgba(4, 14, 11, 0.85);
    box-shadow: 0 0 5px rgba(0, 0, 0, 0.6);
    cursor: pointer;
  }
  :global(.bbox-h.corner) { border-radius: 2px; }
  :global(.bbox-h.edge) { border-radius: 50%; }
  :global(.bbox-h.move) {
    border-radius: 3px;
    display: flex;
    align-items: center;
    justify-content: center;
    color: #7dffbe;
    font-size: 13px;
    line-height: 1;
    cursor: move;
  }
  /* editable-frontline handles */
  :global(.fl-h) {
    box-sizing: border-box;
    border-radius: 50%;
    cursor: move;
    box-shadow: 0 0 5px rgba(0, 0, 0, 0.6);
  }
  :global(.fl-h.vertex) { border: 2px solid var(--amber); background: rgba(4, 14, 11, 0.9); }
  :global(.fl-h.mid) { border: 1px dashed var(--amber); background: rgba(246, 166, 35, 0.28); cursor: copy; }
  :global(.leaflet-tooltip) {
    background: rgba(8, 19, 17, 0.96);
    color: var(--phosphor);
    border: 1px solid var(--edge-hot);
    border-radius: 2px;
    font-family: var(--font-hud);
    font-size: 11px;
    letter-spacing: 0.05em;
    box-shadow: var(--glow);
  }
  :global(.leaflet-tooltip .tt-sub) { color: var(--amber); text-transform: uppercase; font-size: 10px; }
  :global(.leaflet-tooltip .tt-info) { color: var(--ink-dim); font-size: 10px; }
  :global(.leaflet-tooltip-top::before) { border-top-color: var(--edge-hot); }

  /* Locate pulse fired from a list-row click. */
  :global(.ks-flash b) {
    display: block;
    width: 46px;
    height: 46px;
    margin: -23px 0 0 -23px;
    border-radius: 50%;
    border: 3px solid var(--amber);
    box-shadow: 0 0 14px var(--amber);
    animation: ks-flash 1.6s ease-out forwards;
  }
  @keyframes ks-flash {
    0% { transform: scale(0.3); opacity: 1; }
    70% { opacity: 0.6; }
    100% { transform: scale(1.7); opacity: 0; }
  }
</style>
