import proj4 from 'proj4';
import type { LatLon, DcsPoint, Terrain } from './types';
import { TERRAINS } from './terrains';

// ── lat/lon ↔ DCS metres, using each theatre's DCS-extracted proj4 string ────────
//
// The theatre's projString is a Transverse Mercator extracted from DCS itself
// (tools/dcs-export/theatre.lua), so it reproduces the game's own
// convertLatLonToMeters — including the terrain's warp vs true WGS84.
//
// The string carries "+axis=neu" (DCS's north/east/up ordering). proj4js does not
// honour +axis reliably for projected CRS forward/inverse, so we STRIP it and swap
// the axes explicitly here. With +x_0 = east-offset and +y_0 = north-offset,
//   proj4.forward([lon,lat]) = [tm_easting + x_0, tm_northing + y_0] = [dcs.y, dcs.x]
// i.e. result[0] = DCS east (mission Y), result[1] = DCS north (mission X).
// This mapping is confirmed by validateProjection() against the baked anchors.

const ANCHOR_TOLERANCE_M = 2;

const cache = new Map<string, proj4.Converter>();

function converter(terrain: Terrain): proj4.Converter {
  let c = cache.get(terrain.id);
  if (!c) {
    const def = terrain.projString.replace(/\s*\+axis=\S+/g, '');
    c = proj4('WGS84', def);
    cache.set(terrain.id, c);
  }
  return c;
}

export function latLonToDcs(ll: LatLon, terrain: Terrain): DcsPoint {
  const [east, north] = converter(terrain).forward([ll.lon, ll.lat]);
  return { x: north, y: east }; // x = DCS north, y = DCS east
}

export function dcsToLatLon(p: DcsPoint, terrain: Terrain): LatLon {
  const [lon, lat] = converter(terrain).inverse([p.y, p.x]);
  return { lat, lon };
}

export interface ProjCheck {
  terrain: string;
  anchor: string;
  errorM: number;
  ok: boolean;
}

/** Reproduce every baked anchor through proj4 and measure the metre error.
 *  Anchors are DCS-native (lat/lon ↔ metres both from DCS), so error should be
 *  sub-metre; a large error means the axis mapping or the proj string is wrong. */
export function validateProjection(): ProjCheck[] {
  const out: ProjCheck[] = [];
  for (const t of TERRAINS) {
    for (const a of t.anchors) {
      const d = latLonToDcs({ lat: a.lat, lon: a.lon }, t);
      const errorM = Math.hypot(d.x - a.x, d.y - a.z);
      out.push({
        terrain: t.id,
        anchor: `${a.lat.toFixed(3)},${a.lon.toFixed(3)}`,
        errorM,
        ok: errorM <= ANCHOR_TOLERANCE_M,
      });
    }
  }
  return out;
}
