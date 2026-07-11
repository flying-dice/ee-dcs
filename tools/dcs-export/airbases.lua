--[[
    DCS World airbase & parking export.

    Returns an array of GeoJSON Feature (Point) objects for every airbase on the
    currently-loaded theatre, plus a Point per parking spot. Baked into the EECH
    map-generator as an authoritative airbase overlay (real in-game AIRDROME/HELIPAD
    locations) so an author can see where DCS airfields actually are while placing zones.

    Example Feature:
      { "type": "Feature",
        "geometry": { "type": "Point", "coordinates": [37.3597, 45.0131, 43.0] },
        "properties": { "type": "AIRBASE", "id": "Anapa-Vityazevo",
                        "category": "AIRDROME", "name": "Anapa-Vityazevo" } }

    MIT licence — https://opensource.org/licenses/MIT

    USAGE
      Paste into DCS Fiddle, select the GUI environment, with a terrain loaded.
]]--

local features = {}
local categories = { "AIRDROME", "HELIPAD", "SHIP" }

local function addAirbase(airbase)
    local point = Airbase.getPoint(airbase)
    local lat, lon, alt = coord.LOtoLL(point)
    local desc = Airbase.getDesc(airbase)
    table.insert(features, {
        type = "Feature",
        geometry = { type = "Point", coordinates = { lon, lat, alt } },
        properties = {
            type = "AIRBASE",
            id = Airbase.getCallsign(airbase),
            name = desc.displayName,
            category = categories[desc.category + 1],
        },
    })
end

local function addParking(airbase, parking)
    local lat, lon, alt = coord.LOtoLL(parking.vTerminalPos)
    table.insert(features, {
        type = "Feature",
        geometry = { type = "Point", coordinates = { lon, lat, alt } },
        properties = {
            type = "PARKING",
            id = tostring(parking.Term_Index or "TBC"),
            airbase = Airbase.getCallsign(airbase),
        },
    })
end

for _, airbase in pairs(world.getAirbases()) do
    addAirbase(airbase)
    for _, parking in pairs(Airbase.getParking(airbase)) do
        addParking(airbase, parking)
    end
end

return features
