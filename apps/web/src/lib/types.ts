// ── Shared types: the contract between every module ────────────────────────────
// The pipeline is:  bbox + terrain  →  OSM features  →  classified keysites  →
//   balanced keysites (sides + counts)  →  projected zones  →  .miz file.

/** The campaign keysite variants (colour = side, name first word = type), including
 *  the EECH land sub-types and the port's distinct logistics installations:
 *    airbase→AIRBASE  farp→FARP  factory→FACTORY  refinery→OIL_REFINERY  port→PORT
 *    radar→RADIO_TRANSMITTER  power→POWER_STATION  command→MILITARY_BASE
 *  EECH's ANCHORAGE type is naval and unused by the land campaign. */
export type KeysiteType =
  | 'airbase'
  | 'farp'
  | 'factory'
  | 'refinery'
  | 'port'
  | 'radar'
  | 'power'
  | 'command'
  | 'depot'
  | 'fuel';

export const KEYSITE_TYPES: KeysiteType[] = [
  'airbase', 'farp', 'factory', 'refinery', 'port', 'radar', 'power', 'command', 'depot', 'fuel',
];

export type Side = 'blue' | 'red';

/** WGS84 latitude/longitude in decimal degrees. */
export interface LatLon {
  lat: number;
  lon: number;
}

/** A geographic bounding box (the user's selection). */
export interface BBox {
  north: number;
  south: number;
  east: number;
  west: number;
}

/** DCS world coordinates. x = north (mission-editor X), y = east (mission-editor Y,
 *  which is the world Z axis). Matches a trigger-zone's {x, y}. */
export interface DcsPoint {
  x: number;
  y: number;
}

/** A projection self-validation anchor: a (lat, lon) with the DCS-native metres
 *  (x=north, z=east) from terrain.convertLatLonToMeters. proj4 must reproduce these. */
export interface ProjAnchorPt {
  lat: number;
  lon: number;
  x: number; // DCS north
  z: number; // DCS east
}

/** The GeoJSON Feature emitted by tools/dcs-export/theatre.lua (baked into the app,
 *  one file per theatre under src/theatres/). This is the source of truth for a
 *  theatre's bounds + projection — extracted FROM DCS, so self-consistent with the
 *  game's own (warped) terrain rather than assuming true WGS84. */
export interface TheatreFeature {
  type: 'Feature';
  geometry: {
    type: 'Polygon';
    coordinates: number[][][]; // [ring][point][lon, lat]
  };
  properties: {
    type: 'TERRAIN';
    id: string;
    name: string;
    center: { lat: number; lon: number };
    hemisphere: 'n' | 's';
    utm: { zone: number; centralMeridian: number; startLon: number; endLon: number };
    projection: {
      scale: number;
      offset: { x: number; y: number; z: number };
      proj: string; // the proj4 def string
    };
    anchors: ProjAnchorPt[];
  };
}

/** One real parking spot at a DCS airfield (from Airbase.getParking via tools/dcs-export).
 *  Coordinates are DCS world metres: x = north, y = east — placed directly on a baked
 *  Client slot's unit ["x"]/["y"]. termType is DCS's terminal-type code (see MOOSE
 *  AIRBASE.TerminalType): which airframe class the spot fits. */
export interface ParkingSpot {
  termIndex: number;         // Airbase.getParking Term_Index → unit ["parking"]/["parking_id"]
  termType: number;          // Term_Type: 16 runway, 40 heli-only, 68 shelter, 72/104 open, …
  toAc: boolean;             // take-off capable
  x: number;                 // DCS north (metres)
  y: number;                 // DCS east (metres)
  alt: number;               // spot ground elevation (metres) → unit ["alt"]
}

/** A DCS airbase scraped from the terrain (Beacons.lua / world.getAirbases). The
 *  airdromeId + parking spots are present only when the terrain was exported with the
 *  current tools/dcs-export/airbases.lua (older extractions carry name/category/latlon
 *  only — such airbases get no baked Client slots). */
export interface AirbasePoint {
  name: string;
  latlon: LatLon;
  category: string;          // AIRDROME | HELIPAD
  /** Numeric DCS airbase id — equals the mission-file route point ["airdromeId"]. */
  airdromeId?: number;
  /** Airfield reference point in DCS world metres (x = north, y = east). */
  dcs?: DcsPoint;
  /** Real parking spots for baking human-flyable Client slots. */
  parking?: ParkingSpot[];
}

/** The feature list inside a theatre's `src/theatres/<Id>.geojson` (from tools/dcs-export):
 *  a TERRAIN feature plus AIRBASE points and PARKING points joined to their airfield by
 *  `airdromeId`. Used to type the airbase/parking features when splitting the file. */
export interface AirbaseFeatureCollection {
  type: 'FeatureCollection';
  features: {
    type: 'Feature';
    geometry: { type: 'Point'; coordinates: number[] };
    properties: {
      type: 'AIRBASE' | 'PARKING' | string;
      name?: string;
      category?: string;
      airdromeId?: number;
      airbase?: string;
      // AIRBASE ref point / PARKING spot, DCS world metres (x = north, z = east).
      x?: number;
      z?: number;
      // PARKING only:
      Term_Index?: number;
      Term_Type?: number;
      TO_AC?: boolean;
    };
  }[];
}

/** One DCS terrain the tool can target (derived from a TheatreFeature). */
export interface Terrain {
  id: string;                // DCS theatre id, e.g. "Caucasus"
  label: string;             // human name
  center: LatLon;
  /** DCS airbases scraped from the terrain (empty if none baked yet). */
  airbases: AirbasePoint[];
  /** Playable extent as a lon/lat ring — the real, warped quad reported by DCS.
   *  Selection containment is tested against this polygon (not just the bbox). */
  boundsPolygon: LatLon[];
  /** Axis-aligned bbox of the polygon — for compiled OSM filtering + quick pre-checks. */
  bounds: BBox;
  /** proj4 def string extracted from DCS (reproduces convertLatLonToMeters exactly). */
  projString: string;
  /** Self-validation anchors baked from the extraction (may be empty on old files). */
  anchors: ProjAnchorPt[];
  /** True when anchors exist to confirm the projection. */
  projectionValidated: boolean;
  /** Default map view centre + zoom for a nice initial framing. */
  view: { center: LatLon; zoom: number };
}

/** A feature loaded from the theatre's pre-exported OSM GeoJSON. */
export interface OsmFeature {
  id: string;                // "node/123", "way/456", "relation/789"
  latlon: LatLon;            // representative point (centroid for ways/relations)
  tags: Record<string, string>;
  name?: string;
  /** Baked campaign keysite enum, also visible as GeoJSON `kind`. */
  kind?: KeysiteType;
}

/** A named real-world feature that can anchor an operational objective. */
export interface ObjectiveFeature {
  id: string;
  kind: 'settlement' | 'key-terrain';
  name: string;
  latlon: LatLon;
  tags: Record<string, string>;
}

/** One authored rear-to-forward operation, terminating at a real objective. */
export interface OperationAxis {
  id: string;
  start: LatLon;
  objective: ObjectiveFeature;
}

/** User-authored operational function for an H3 cell. */
export type TerritoryRole = 'rear' | 'close';

export interface TerritoryAssignment {
  side: Side;
  role: TerritoryRole;
}

/** A resolution-5 H3 cell carrying its explicit scenario assignment. */
export interface AssignedTerritory {
  id: string;
  name: string;
  owner: Side;
  role: TerritoryRole;
  bounds: BBox;
  areaKm2: number;
  representativePoint: LatLon;
}

/** Immutable territorial input to keysite generation. */
export interface TerritoryPlan {
  territories: AssignedTerritory[];
  byCell: Readonly<Record<string, AssignedTerritory>>;
  bounds: BBox | null;
  ownerCounts: Record<Side, number>;
}

/** An OSM feature classified into a candidate keysite (pre-balancing, pre-side). */
export interface CandidateKeysite {
  type: KeysiteType;
  latlon: LatLon;
  name: string;              // sanitised label (a-z0-9), used to build the zone name
  /** Classification confidence / priority for balancing selection (higher = better). */
  score: number;
  source: OsmFeature;
}

/** A final keysite: type + side + label, ready to become a zone. */
export interface Keysite {
  /** Stable identity for add/remove + selection tracking. `ab:<name>` for a DCS
   *  airbase, `osm:<source.id>` for an OpenStreetMap-derived site. */
  id: string;
  type: KeysiteType;
  side: Side;
  latlon: LatLon;
  label: string;             // unique within its type
  radiusM: number;           // zone radius in metres
  name: string;              // human display name (airbase/site name)
  /** False for generated sites whose position can be adjusted by the designer. */
  locationTied: boolean;
  /** Whether this is a side's designated main airbase (force-included). */
  isMain?: boolean;
  /** Source detail for the map tooltip (OSM tags, or {category} for a DCS airbase). */
  tags?: Record<string, string>;
}

/** Per-keysite-type target counts, independently settable per side. Airbase counts
 *  include each side's main. Non-base types are filled from OpenStreetMap. */
export type CountConfig = Record<KeysiteType, { blue: number; red: number }>;

/** A user's manual override to force-include a specific site the balancer didn't pick
 *  (or picked and the user re-added). Survives shuffles. */
export interface AddedKeysite {
  id: string;
  type: KeysiteType;
  side: Side;
  latlon: LatLon;
  name: string;
  tags?: Record<string, string>;
}

/** A DCS trigger zone as it appears in the mission file's triggers.zones list. */
export interface DcsZone {
  zoneId: number;
  name: string;              // "<type>_<label>" — first word is the type
  x: number;                 // DCS north
  y: number;                 // DCS east
  radius: number;
  color: [number, number, number, number]; // r,g,b,a in 0..1 (blue={0,0,1}, red={1,0,0})
  side: Side;
  type: KeysiteType;
}

/** Options that drive balancing (README: 1-2 airbases, 3-6 farps, ~12-20 total per
 *  side, farp:airbase ~3:1). Sensible defaults live in balance.ts. */
export interface BalanceOptions {
  airbasesPerSide: number;   // target
  farpsPerSide: number;      // target
  totalPerSide: number;      // soft cap on all keysites per side
  /** Minimum spacing between two kept keysites of the same kind, metres. */
  minSpacingM: number;
}

/** What the mission designer draws on the map. Sides are split by the frontline the
 *  user draws; the side containing mainBlue is BLUE, the other RED. Each side's main
 *  airbase is force-included as that side's primary airbase keysite. */
export interface DesignInput {
  /** Theatre-area rectangle (the region OSM is queried over + zones live in). */
  bbox: BBox;
  /** Initial frontline polyline (>= 2 points) dividing BLUE from RED. */
  frontline: LatLon[];
  /** Designated main airbase per side (the nearest airbase candidate is used). */
  mainBlue?: LatLon;
  mainRed?: LatLon;
  /** Unordered named settlements/key terrain that establish the operational frontage. */
  objectives: ObjectiveFeature[];
}
