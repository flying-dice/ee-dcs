/** @noSelfInFile */
/*
-- payloads.lua
-- Weapon pylon tables for all spawned aircraft.
-- Mirrors: aphavoc/source/entity/helicopter/he_funcs.c (load_helicopter_payload),
--          aphavoc/source/entity/fixedwing/fw_funcs.c (load_fixedwing_payload)
--
-- All CLSIDs verified against live DCS install:
--   CoreMods/aircraft/F-16C/UnitPayloads/F-16C_50.lua
--   CoreMods/aircraft/AH-64D/UnitPayloads/AH-64D_BLK_II.lua
--   MissionEditor/data/scripts/UnitPayloads/{F-15C,Su-25T,Su-27,Mi-24V}.lua
*/
export const F16_STRIKER: PylonData[] = [
	{ CLSID: "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", num: 1 },
	{ CLSID: "{5CE2FF2A-645A-4197-B48D-8720AC69394F}", num: 2 },
	{ CLSID: "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}", num: 3 },
	{ CLSID: "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}", num: 4 },
	{ CLSID: "{A111396E-D3E8-4b9c-8AC9-2432489304D5}", num: 5 },
	{ CLSID: "{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}", num: 6 },
	{ CLSID: "{DB769D48-67D7-42ED-A2BE-108D566C8B1E}", num: 7 },
	{ CLSID: "{5CE2FF2A-645A-4197-B48D-8720AC69394F}", num: 8 },
	{ CLSID: "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", num: 9 },
];
export const F15_ESCORT: PylonData[] = [
	{ CLSID: "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", num: 1 },
	{ CLSID: "{E1F29B21-F291-4589-9FD8-3272EEC69506}", num: 2 },
	{ CLSID: "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", num: 3 },
	{ CLSID: "{C8E06185-7CD6-4C90-959F-044679E90751}", num: 4 },
	{ CLSID: "{C8E06185-7CD6-4C90-959F-044679E90751}", num: 5 },
	{ CLSID: "{E1F29B21-F291-4589-9FD8-3272EEC69506}", num: 6 },
	{ CLSID: "{C8E06185-7CD6-4C90-959F-044679E90751}", num: 7 },
	{ CLSID: "{C8E06185-7CD6-4C90-959F-044679E90751}", num: 8 },
	{ CLSID: "{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", num: 9 },
	{ CLSID: "{E1F29B21-F291-4589-9FD8-3272EEC69506}", num: 10 },
	{ CLSID: "{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", num: 11 },
];
export const SU25T_STRIKER: PylonData[] = [
	{ CLSID: "{44EE8698-89F9-48EE-AF36-5FD31896A82D}", num: 1 },
	{ CLSID: "{CBC29BFE-3D24-4C64-B81D-941239D12249}", num: 2 },
	{ CLSID: "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}", num: 3 },
	{ CLSID: "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}", num: 5 },
	{ CLSID: "{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}", num: 7 },
	{ CLSID: "{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}", num: 9 },
	{ CLSID: "{CBC29BFE-3D24-4C64-B81D-941239D12249}", num: 10 },
	{ CLSID: "{44EE8698-89F9-48EE-AF36-5FD31896A82C}", num: 11 },
];
export const SU27_ESCORT: PylonData[] = [
	{ CLSID: "{FBC29BFE-3D24-4C64-B81D-941239D12249}", num: 1 },
	{ CLSID: "{FBC29BFE-3D24-4C64-B81D-941239D12249}", num: 2 },
	{ CLSID: "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}", num: 3 },
	{ CLSID: "{E8069896-8435-4B90-95C0-01A03AE6E400}", num: 4 },
	{ CLSID: "{E8069896-8435-4B90-95C0-01A03AE6E400}", num: 5 },
	{ CLSID: "{E8069896-8435-4B90-95C0-01A03AE6E400}", num: 6 },
	{ CLSID: "{E8069896-8435-4B90-95C0-01A03AE6E400}", num: 7 },
	{ CLSID: "{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}", num: 8 },
	{ CLSID: "{FBC29BFE-3D24-4C64-B81D-941239D12249}", num: 9 },
	{ CLSID: "{FBC29BFE-3D24-4C64-B81D-941239D12249}", num: 10 },
];
export const AH64D_CAP: PylonData[] = [
	{ CLSID: "M261_MK151", num: 1 },
	{ CLSID: "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}", num: 2 },
	{ CLSID: "{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}", num: 3 },
	{ CLSID: "M261_MK151", num: 4 },
	{ CLSID: "{IAFS_ComboPak_100}", num: 5 },
	{ CLSID: "{AN_APG_78}", num: 6 },
];
export const MI24V_CAP: PylonData[] = [
	{ CLSID: "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}", num: 1 },
	{ CLSID: "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num: 2 },
	{ CLSID: "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num: 3 },
	{ CLSID: "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num: 4 },
	{ CLSID: "{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num: 5 },
	{ CLSID: "{B919B0F4-7C25-455E-9A02-CEA51DB895E3}", num: 6 },
];

export function build(pylon_list: readonly PylonData[]): PayloadData {
	return {
		fuel: 100,
		gun: 100,
		pylons: pylon_list.map((pylon) => ({ CLSID: pylon.CLSID, num: pylon.num })),
		unlimited: { fuel: false, guns: false, flares: false, chaff: false },
	};
}
