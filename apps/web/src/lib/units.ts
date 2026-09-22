// ── units.ts — configurable DCS aircraft types + DMT_CONFIG override builder ─────
// The campaign spawns aircraft from the port's config.lua defaults. The generator lets
// the author override the aircraft TYPE NAMES per role per side as free text. When the
// campaign Lua is baked into the .miz, a `_G.DMT_CONFIG` snippet is prepended so the
// port's config.lua picks the overrides up at load — its documented override hook
// ("set a global table _G.DMT_CONFIG before the campaign loads"). Ground / static / other
// config stays on the port defaults.

export type AircraftRole =
  | 'striker'
  | 'escort'
  | 'recon'
  | 'attack_heli'
  | 'transport_heli'
  | 'transport_fw'
  | 'transport_fw_heavy';

/** Display order + labels for the editor (one text box per role per side). */
export const AIRCRAFT_ROLES: { key: AircraftRole; label: string }[] = [
  { key: 'striker', label: 'Strike (fixed-wing)' },
  { key: 'escort', label: 'Fighter / escort' },
  { key: 'recon', label: 'Recon (fixed-wing)' },
  { key: 'attack_heli', label: 'Attack helicopter' },
  { key: 'transport_heli', label: 'Transport helicopter' },
  { key: 'transport_fw', label: 'Transport — medium' },
  { key: 'transport_fw_heavy', label: 'Transport — heavy' },
];

export type SideUnits = Record<AircraftRole, string>;
export interface UnitTypes {
  blue: SideUnits;
  red: SideUnits;
}

// Mirrors the port's config.lua DEFAULTS.types.aircraft (verified DCS type names).
export const DEFAULT_UNIT_TYPES: UnitTypes = {
  blue: {
    striker: 'F-16C bl.52d',
    escort: 'F-15C',
    recon: 'F-15C',
    attack_heli: 'AH-64D',
    transport_heli: 'UH-60A',
    transport_fw: 'C-130',
    transport_fw_heavy: 'C-17A',
  },
  red: {
    striker: 'Su-25T',
    escort: 'Su-27',
    recon: 'Su-27',
    attack_heli: 'Mi-24V',
    transport_heli: 'Mi-8MT',
    transport_fw: 'An-26B',
    transport_fw_heavy: 'IL-76MD',
  },
};

function luaStr(s: string): string {
  return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

/** True if any unit type differs from the port defaults. */
export function unitsChanged(u: UnitTypes): boolean {
  return (['blue', 'red'] as const).some((side) =>
    AIRCRAFT_ROLES.some((r) => (u[side][r.key] ?? '').trim() !== DEFAULT_UNIT_TYPES[side][r.key]),
  );
}

/**
 * A `_G.DMT_CONFIG` Lua snippet overriding the aircraft types, or '' when everything is
 * default. Prepended to the baked campaign bundle so config.lua reads it at load. Emits
 * the FULL aircraft table (both sides, all roles) so the override is complete regardless
 * of the port's per-key merge semantics; blank fields fall back to the default type.
 */
export function unitConfigLua(u: UnitTypes): string {
  if (!unitsChanged(u)) return '';
  const sideLua = (side: 'blue' | 'red'): string =>
    AIRCRAFT_ROLES.map((r) => {
      const v = (u[side][r.key] ?? '').trim() || DEFAULT_UNIT_TYPES[side][r.key];
      return `    ${r.key} = ${luaStr(v)},`;
    }).join('\n');
  return (
    '-- Aircraft unit-type overrides from the EE-DCS Campaign Generator.\n' +
    '_G.DMT_CONFIG = _G.DMT_CONFIG or {}\n' +
    '_G.DMT_CONFIG.types = _G.DMT_CONFIG.types or {}\n' +
    '_G.DMT_CONFIG.types.aircraft = {\n' +
    '  blue = {\n' +
    sideLua('blue') +
    '\n  },\n' +
    '  red = {\n' +
    sideLua('red') +
    '\n  },\n' +
    '}\n\n'
  );
}
