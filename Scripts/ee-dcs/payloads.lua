-- payloads.lua
-- Weapon pylon tables for all spawned aircraft.
-- Mirrors: aphavoc/source/entity/helicopter/he_funcs.c (load_helicopter_payload),
--          aphavoc/source/entity/fixedwing/fw_funcs.c (load_fixedwing_payload)
--
-- All CLSIDs verified against live DCS install:
--   CoreMods/aircraft/F-16C/UnitPayloads/F-16C_50.lua
--   CoreMods/aircraft/AH-64D/UnitPayloads/AH-64D_BLK_II.lua
--   MissionEditor/data/scripts/UnitPayloads/{F-15C,Su-25T,Su-27,Mi-24V}.lua

local M = {}

-- ── BLUE FIXED-WING ──────────────────────────────────────────────────────────

-- F-16C bl.52d striker: AIM-120C*2, AIM-9X*2, GBU-12*2, 370gal*2, TGP
-- Pylon layout: 1=L wingtip, 2=L outer, 3=L mid, 4=L inner,
--               5=centerline, 6=R inner, 7=R mid, 8=R outer, 9=R wingtip
M.F16_STRIKER = {
    {CLSID="{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", num=1},  -- AIM-120C
    {CLSID="{5CE2FF2A-645A-4197-B48D-8720AC69394F}", num=2},  -- AIM-9X
    {CLSID="{DB769D48-67D7-42ED-A2BE-108D566C8B1E}", num=3},  -- GBU-12
    {CLSID="{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}", num=4},  -- 370gal tank
    {CLSID="{A111396E-D3E8-4b9c-8AC9-2432489304D5}", num=5},  -- LITENING TGP
    {CLSID="{F376DBEE-4CAE-41BA-ADD9-B2910AC95DEC}", num=6},  -- 370gal tank
    {CLSID="{DB769D48-67D7-42ED-A2BE-108D566C8B1E}", num=7},  -- GBU-12
    {CLSID="{5CE2FF2A-645A-4197-B48D-8720AC69394F}", num=8},  -- AIM-9X
    {CLSID="{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", num=9},  -- AIM-120C
}

-- F-15C escort: AIM-120C*2 wingtip, AIM-120B*4 fuselage, AIM-9M*2, fuel*3
-- Pylon layout: 1=L wingtip, 2=L outer, 3=L inner, 4-5=L fuse,
--               6=centerline, 7-8=R fuse, 9=R inner, 10=R outer, 11=R wingtip
M.F15_ESCORT = {
    {CLSID="{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", num=1},  -- AIM-120C
    {CLSID="{E1F29B21-F291-4589-9FD8-3272EEC69506}", num=2},  -- 600gal tank
    {CLSID="{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", num=3},  -- AIM-9M
    {CLSID="{C8E06185-7CD6-4C90-959F-044679E90751}", num=4},  -- AIM-120B
    {CLSID="{C8E06185-7CD6-4C90-959F-044679E90751}", num=5},  -- AIM-120B
    {CLSID="{E1F29B21-F291-4589-9FD8-3272EEC69506}", num=6},  -- 600gal tank
    {CLSID="{C8E06185-7CD6-4C90-959F-044679E90751}", num=7},  -- AIM-120B
    {CLSID="{C8E06185-7CD6-4C90-959F-044679E90751}", num=8},  -- AIM-120B
    {CLSID="{6CEB49FC-DED8-4DED-B053-E1F033FF72D3}", num=9},  -- AIM-9M
    {CLSID="{E1F29B21-F291-4589-9FD8-3272EEC69506}", num=10}, -- 600gal tank
    {CLSID="{40EF17B7-F508-45de-8566-6FFECC0C1AB8}", num=11}, -- AIM-120C
}

-- ── RED FIXED-WING ────────────────────────────────────────────────────────────

-- Su-25T striker: Kh-29T*2 (TV-guided AGM), R-73*2 (IR self-defence), fuel*2, MPS-410 ECM
-- Verified from payload "Kh-29T*2,R-73*2,Fuel*2,MPS-410" in Su-25T.lua
-- Pylon: 1=L wingtip ECM, 2=L outer AAM, 3=L inner fuel, 5=L AGM,
--        7=R AGM, 9=R inner fuel, 10=R outer AAM, 11=R wingtip ECM
M.SU25T_STRIKER = {
    {CLSID="{44EE8698-89F9-48EE-AF36-5FD31896A82D}", num=1},  -- MPS-410 ECM (left)
    {CLSID="{CBC29BFE-3D24-4C64-B81D-941239D12249}", num=2},  -- R-73
    {CLSID="{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}", num=3},  -- fuel tank
    {CLSID="{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}", num=5},  -- Kh-29T
    {CLSID="{601C99F7-9AF3-4ed7-A565-F8B8EC0D7AAC}", num=7},  -- Kh-29T
    {CLSID="{E8D4652F-FD48-45B7-BA5B-2AE05BB5A9CF}", num=9},  -- fuel tank
    {CLSID="{CBC29BFE-3D24-4C64-B81D-941239D12249}", num=10}, -- R-73
    {CLSID="{44EE8698-89F9-48EE-AF36-5FD31896A82C}", num=11}, -- MPS-410 ECM (right)
}

-- Su-27 escort: R-73*4 (IR), R-27ER*4 (SARH BVR), R-27ET*2 (IR BVR), ECM
-- Verified from payload "R-73*4,R-27ER*4,R-27ET*2" in Su-27.lua
-- Pylon: 1,10=wingtip R-73; 2,9=outer R-73; 3,8=R-27ET; 4-7=R-27ER belly
M.SU27_ESCORT = {
    {CLSID="{FBC29BFE-3D24-4C64-B81D-941239D12249}", num=1},  -- R-73
    {CLSID="{FBC29BFE-3D24-4C64-B81D-941239D12249}", num=2},  -- R-73
    {CLSID="{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}", num=3},  -- R-27ET
    {CLSID="{E8069896-8435-4B90-95C0-01A03AE6E400}", num=4},  -- R-27ER
    {CLSID="{E8069896-8435-4B90-95C0-01A03AE6E400}", num=5},  -- R-27ER
    {CLSID="{E8069896-8435-4B90-95C0-01A03AE6E400}", num=6},  -- R-27ER
    {CLSID="{E8069896-8435-4B90-95C0-01A03AE6E400}", num=7},  -- R-27ER
    {CLSID="{B79C379A-9E87-4E50-A1EE-7F7E29C2E87A}", num=8},  -- R-27ET
    {CLSID="{FBC29BFE-3D24-4C64-B81D-941239D12249}", num=9},  -- R-73
    {CLSID="{FBC29BFE-3D24-4C64-B81D-941239D12249}", num=10}, -- R-73
}

-- ── BLUE ROTARY-WING ─────────────────────────────────────────────────────────

-- AH-64D: 4x AGM-114K Hellfire (inboard), 2x M261 Hydra-70 (outboard), FCR
-- Verified from AH-64D_BLK_II.lua constants:
--   HellfireLauncherID_AGM114K_4 = {88D18A5E-99C8-4B04-B40B-1C02F2018B6E}
--   NURSLauncherID_MK151 = M261_MK151
--   InternalFuelTank100 = {IAFS_ComboPak_100}
--   FCR = {AN_APG_78}
M.AH64D_CAP = {
    {CLSID="M261_MK151",                              num=1}, -- Hydra M261 (left outer)
    {CLSID="{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}", num=2}, -- 4x AGM-114K
    {CLSID="{88D18A5E-99C8-4B04-B40B-1C02F2018B6E}", num=3}, -- 4x AGM-114K
    {CLSID="M261_MK151",                              num=4}, -- Hydra M261 (right outer)
    {CLSID="{IAFS_ComboPak_100}",                    num=5}, -- internal fuel (required)
    {CLSID="{AN_APG_78}",                             num=6}, -- FCR
}

-- ── RED ROTARY-WING ───────────────────────────────────────────────────────────

-- Mi-24V: 4x 9M114 Shturm ATGM (outer), 4x S-8 rocket pods (inner)
-- Verified from payload "4x9M114, 80xS-8" in Mi-24V.lua:
--   9M114 = {B919B0F4-7C25-455E-9A02-CEA51DB895E3} on pylon 1, 6
--   S-8 pod = {6A4B9E69-64FE-439a-9163-3A87FB6A4D81} on pylons 2-5
M.MI24V_CAP = {
    {CLSID="{B919B0F4-7C25-455E-9A02-CEA51DB895E3}", num=1}, -- 9M114 x4 (left outer)
    {CLSID="{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num=2}, -- S-8 20-round
    {CLSID="{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num=3}, -- S-8 20-round
    {CLSID="{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num=4}, -- S-8 20-round
    {CLSID="{6A4B9E69-64FE-439a-9163-3A87FB6A4D81}", num=5}, -- S-8 20-round
    {CLSID="{B919B0F4-7C25-455E-9A02-CEA51DB895E3}", num=6}, -- 9M114 x4 (right outer)
}

-- ── HELPERS ───────────────────────────────────────────────────────────────────

-- Build DCS payload block from a pylon table.
-- Returns { fuel=100, gun=100, pylons={...}, unlimited={fuel=false, guns=false, flares=false, chaff=false} }
function M.build(pylon_list)
    local pylons = {}
    for i, p in ipairs(pylon_list) do
        pylons[i] = {CLSID=p.CLSID, num=p.num}
    end
    return {
        fuel     = 100,
        gun      = 100,
        pylons   = pylons,
        unlimited = {fuel=false, guns=false, flares=false, chaff=false},
    }
end

return M
