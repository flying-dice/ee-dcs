/** @typedef {import('./types').KeysiteType} KeysiteType */

const REFINERY_NAME = /\brefiner(?:y|ies)\b|нефтеперераб|\bнпз\b|ნავთობგადამამუშავ/iu;
const FUEL_NAME = /\b(?:fuel|oil|petroleum)\s+(?:depot|terminal|storage)\b|\b(?:tank farm|oil depot)\b|нефтебаз|нефтехранилищ|склад\s*(?:гсм|горюче)|топливн.*склад|ნავთობტერმინალ/iu;
const PUMP_NAME = /\b(?:pump(?:ing)?|compressor)\s+station\b|насосн(?:ая|ой)\s+станц|компрессорн(?:ая|ой)\s+станц|\bнпс\b|помпа\s+истас/iu;
const SERVICE_NAME = /\b(?:rail|trolleybus)\s+depot\b|\bwater\s+(?:pumping|treatment)\b|\bcompressor\s+station\b|депо|насосн(?:ая|ой)\s+станц|компрессорн(?:ая|ой)\s+станц/iu;
const DRY_PORT_NAME = /\bdry\s+port\b|сухо[йг]\s+порт/iu;
const GENERIC_BARRACKS_NAME = /^(?:barracks?|казармы|კაზარმები)$/iu;
const MARITIME_NAME = /port|harbo[u]?r|liman|terminal|морск|порт|ნავსადგურ/iu;
const INDUSTRIAL_PARK_NAME = /\b(?:industrial|organized\s+industrial)\s+(?:area|zone|park)\b|organize\s+sanayi\s+bölgesi|промышленн.*зон/iu;
const AIRPORT_FUEL_NAME = /\bairport\b|аэропорт/iu;
const CIVIC_CENTRE_NAME = /\bcivic\s+cent(?:re|er)\b/iu;

/** @param {Record<string, string>} tags */
function largeGeneratingPlant(tags) {
  if (tags.power !== 'plant' && tags.man_made !== 'power_station') return false;
  const output = /^(\d+(?:[.,]\d+)?)\s*(kW|MW|GW)$/i.exec(tags['plant:output:electricity'] ?? '');
  if (!output) return false;
  const multiplier = { kw: 0.001, mw: 1, gw: 1000 }[/** @type {'kw' | 'mw' | 'gw'} */ (output[2].toLowerCase())];
  return Number(output[1].replace(',', '.')) * multiplier >= 100;
}

/** @param {Record<string, string>} tags */
function majorSubstation(tags) {
  if (tags.power !== 'substation') return false;
  if (['minor_distribution', 'traction', 'industrial', 'transport', 'transition'].includes(tags.substation)) return false;
  return (tags.voltage ?? '').split(';').some((value) => {
    const volts = value.trim();
    return /^\d+$/u.test(volts) && Number(volts) >= 220_000;
  });
}

/**
 * Classify one campaign spawn type per mapped site.
 * The exporter and browser both use this policy so visible `kind` cannot drift.
 * @param {Record<string, string>} tags
 * @param {string} osmId
 * @param {string | undefined} name
 * @returns {{ type: KeysiteType, score: number } | null}
 */
export function classifyOsmSite(tags, osmId, name) {
  const area = osmId.startsWith('way/') || osmId.startsWith('relation/') || osmId.startsWith('a');
  const label = name ?? '';
  const named = !!label.trim();
  const warehouse = tags.industrial === 'warehouse' || tags.building === 'warehouse' ||
    tags['building:use'] === 'warehouse' || tags.amenity === 'warehouse';
  const militaryArea = area && tags.landuse === 'military';
  const civicSite = area && (tags.amenity === 'townhall' || tags.office === 'government' ||
    tags.building === 'government' || tags.building === 'government_office' ||
    CIVIC_CENTRE_NAME.test(label) && (tags.building === 'civic' || tags.amenity === 'community_centre'));
  const specificMilitaryArea = area && ['base', 'naval_base', 'barracks', 'depot', 'ammunition'].includes(tags.military);
  const majorPowerArea = area && majorSubstation(tags);
  if (!named && !warehouse && !(area && tags.landuse === 'industrial') && !militaryArea &&
    !specificMilitaryArea && !civicSite && !majorPowerArea) return null;

  if (named && (tags.man_made === 'petroleum_refinery' || tags.industrial === 'refinery' ||
    (tags.industrial === 'oil' && REFINERY_NAME.test(label)))) return { type: 'refinery', score: 100 };
  if (named && (tags.military === 'radar_station' || tags.man_made === 'radar')) return { type: 'radar', score: 85 };
  if (named && largeGeneratingPlant(tags)) return { type: 'power', score: 90 };
  if (majorPowerArea) return { type: 'power', score: 85 };
  if (named && area && tags.amenity === 'ferry_terminal') return { type: 'port', score: 80 };
  if (named && area && !DRY_PORT_NAME.test(label) && !AIRPORT_FUEL_NAME.test(label) &&
    (tags.landuse === 'harbour' || tags.harbour === 'yes' ||
      tags.industrial === 'port' && MARITIME_NAME.test(label))) return { type: 'port', score: 75 };
  if (named && area && (tags.man_made === 'tank_farm' || tags.landuse === 'depot' && /fuel|oil|petro/i.test(tags.substance ?? tags.resource ?? '') ||
    tags.industrial === 'oil' && FUEL_NAME.test(label) && !PUMP_NAME.test(label) && !AIRPORT_FUEL_NAME.test(label))) return { type: 'fuel', score: 72 };
  if (named && (tags.military === 'depot' || tags.military === 'ammunition')) return { type: 'depot', score: 75 };
  if (area && (tags.military === 'depot' || tags.military === 'ammunition')) return { type: 'depot', score: 55 };
  if (named && (tags.military === 'base' || tags.military === 'naval_base' ||
    tags.military === 'barracks' && !GENERIC_BARRACKS_NAME.test(label))) return { type: 'command', score: 70 };
  if (area && (tags.military === 'base' || tags.military === 'naval_base')) return { type: 'command', score: 60 };
  if (area && tags.military === 'barracks') return { type: 'command', score: 55 };
  if (militaryArea && (!tags.military || tags.military === 'yes')) return { type: 'command', score: 35 };
  if (civicSite) return { type: 'command', score: 40 };
  if (warehouse) return { type: 'depot', score: 50 };
  if (named && !SERVICE_NAME.test(label) && !INDUSTRIAL_PARK_NAME.test(label) && label.toLowerCase() !== 'весы' &&
    !/^(?:oil|petroleum|fuel)$/i.test(tags.product ?? '') &&
    (tags.industrial === 'factory' || tags.man_made === 'works' && !!tags.product?.trim())) {
    return { type: 'factory', score: tags.industrial === 'factory' ? 72 + (tags.product ? 8 : 0) : 68 };
  }
  if (area && tags.landuse === 'industrial') return { type: 'factory', score: 35 };
  return null;
}
